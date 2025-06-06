/*
 * Copyright © Advanced Micro Devices, Inc. All rights reserved.
 * Copyright (c) 2024, The vLLM team.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
#include <torch/all.h>
#include <ATen/cuda/CUDAContext.h>
#include <c10/cuda/CUDAGuard.h>

#include "hip_compat.h"
#include "dispatch_utils.h"

namespace vllm
{

  template <typename scalar_t, bool IS_NEOX>
  inline __device__ void apply_token_rotary_embedding(
      scalar_t *__restrict__ arr, const scalar_t *__restrict__ cos_ptr,
      const scalar_t *__restrict__ sin_ptr, int rot_offset, int embed_dim)
  {
    int x_index, y_index;
    scalar_t cos, sin;
    if (IS_NEOX)
    {
      // GPT-NeoX style rotary embedding.
      x_index = rot_offset;
      y_index = embed_dim + rot_offset;
      cos = VLLM_LDG(cos_ptr + x_index);
      sin = VLLM_LDG(sin_ptr + x_index);
    }
    else
    {
      // GPT-J style rotary embedding.
      x_index = 2 * rot_offset;
      y_index = 2 * rot_offset + 1;
      cos = VLLM_LDG(cos_ptr + x_index / 2);
      sin = VLLM_LDG(sin_ptr + x_index / 2);
    }

    const scalar_t x = arr[x_index];
    const scalar_t y = arr[y_index];
    arr[x_index] = x * cos - y * sin;
    arr[y_index] = y * cos + x * sin;
  }

  template <typename scalar_t, bool IS_NEOX, bool is_nope_first>
  inline __device__ void apply_rotary_embedding(
      scalar_t *__restrict__ query, // [batch_size, seq_len, num_heads,
                                    // head_size] or [num_tokens, num_heads,
                                    // head_size]
      scalar_t *__restrict__ key,   // [batch_size, seq_len, num_kv_heads,
                                    // head_size] or [num_tokens, num_kv_heads,
                                    // head_size]
      const scalar_t *cos_ptr, const scalar_t *sin_ptr, 
      const int head_size, const int num_heads,
      const int num_kv_heads, const int rot_dim, const int token_idx,
      const int64_t query_stride, const int64_t key_stride)
  {
    const int embed_dim = rot_dim / 2;
    // const scalar_t *cos_ptr = cache_ptr;
    // const scalar_t *sin_ptr = cache_ptr + embed_dim;

    const int nq = num_heads * embed_dim;
    if (is_nope_first)
    {
      query += head_size - rot_dim;
      key += head_size - rot_dim;
    }

    for (int i = threadIdx.x; i < nq; i += blockDim.x)
    {
      const int head_idx = i / embed_dim;
      const int64_t token_head = token_idx * query_stride + head_idx * head_size;
      const int rot_offset = i % embed_dim;
      apply_token_rotary_embedding<scalar_t, IS_NEOX>(
          query + token_head, cos_ptr, sin_ptr, rot_offset, embed_dim);
    }

    const int nk = num_kv_heads * embed_dim;
    for (int i = threadIdx.x; i < nk; i += blockDim.x)
    {
      const int head_idx = i / embed_dim;
      const int64_t token_head = token_idx * key_stride + head_idx * head_size;
      const int rot_offset = i % embed_dim;
      apply_token_rotary_embedding<scalar_t, IS_NEOX>(
          key + token_head, cos_ptr, sin_ptr, rot_offset, embed_dim);
    }
  }

  template <typename scalar_t, bool IS_NEOX, bool is_nope_first>
  __global__ void rotary_embedding_kernel(
      const int64_t *__restrict__ positions,      // [batch_size, seq_len] or
                                                  // [num_tokens]
      scalar_t *__restrict__ query,               // [batch_size, seq_len, num_heads,
                                                  // head_size] or [num_tokens, num_heads,
                                                  // head_size]
      scalar_t *__restrict__ key,                 // [batch_size, seq_len, num_kv_heads,
                                                  // head_size] or [num_tokens, num_kv_heads,
                                                  // head_size]
      const scalar_t *__restrict__ cos_cache,        // [max_position, rot_dim //2]
      const scalar_t *__restrict__ sin_cache,        // [max_position, rot_dim //2]
      const int rot_dim, const int64_t query_stride, const int64_t key_stride,
      const int num_heads, const int num_kv_heads, const int head_size)
  {
    // Each thread block is responsible for one token.
    const int token_idx = blockIdx.x;
    int64_t pos = positions[token_idx];
    int64_t cos_sin_cache_offset = pos * rot_dim / 2;
    const scalar_t *cos_ptr = cos_cache + cos_sin_cache_offset;
    const scalar_t *sin_ptr = sin_cache + cos_sin_cache_offset;

    apply_rotary_embedding<scalar_t, IS_NEOX, is_nope_first>(
        query, key, cos_ptr, sin_ptr, head_size, num_heads, num_kv_heads, rot_dim,
        token_idx, query_stride, key_stride);
  }

  template <typename scalar_t, bool IS_NEOX, bool is_nope_first>
  __global__ void batched_rotary_embedding_kernel(
      const int64_t *__restrict__ positions,             // [batch_size, seq_len] or
                                                         // [num_tokens]
      scalar_t *__restrict__ query,                      // [batch_size, seq_len, num_heads,
                                                         // head_size] or [num_tokens, num_heads,
                                                         // head_size]
      scalar_t *__restrict__ key,                        // [batch_size, seq_len, num_kv_heads,
                                                         // head_size] or [num_tokens, num_kv_heads,
                                                         // head_size]
      const scalar_t *__restrict__ cos_cache,        // [max_position, rot_dim //2]
      const scalar_t *__restrict__ sin_cache,        // [max_position, rot_dim //2]
      const int64_t *__restrict__ cos_sin_cache_offsets, // [batch_size, seq_len]
                                                         // or [num_tokens]
      const int rot_dim, const int64_t query_stride, const int64_t key_stride,
      const int num_heads, const int num_kv_heads, const int head_size)
  {
    // Each thread block is responsible for one token.
    const int token_idx = blockIdx.x;
    int64_t pos = positions[token_idx];
    int64_t cos_sin_cache_offset = cos_sin_cache_offsets[token_idx];
    int64_t cos_sin_cache_offset2 = (cos_sin_cache_offset + pos) * rot_dim/2;
    const scalar_t *cos_ptr =
        cos_cache + cos_sin_cache_offset2;
    const scalar_t *sin_ptr =
        sin_cache + cos_sin_cache_offset2;

    apply_rotary_embedding<scalar_t, IS_NEOX, is_nope_first>(
        query, key, cos_ptr, sin_ptr, head_size, num_heads, num_kv_heads, rot_dim,
        token_idx, query_stride, key_stride);
  }

} // namespace vllm

void rotary_embedding(
    torch::Tensor &positions, // [batch_size, seq_len] or [num_tokens]
    torch::Tensor &query,     // [batch_size, seq_len, num_heads * head_size] or
                              // [num_tokens, num_heads * head_size]
    torch::Tensor &key,       // [batch_size, seq_len, num_kv_heads * head_size] or
                              // [num_tokens, num_kv_heads * head_size]
    int64_t head_size,
    torch::Tensor &cos_cache, // [max_position, rot_dim//2]
    torch::Tensor &sin_cache, // [max_position, rot_dim//2]
    bool is_neox, bool is_nope_first)
{
  int64_t num_tokens = query.numel() / query.size(-1);
  int rot_dim = cos_cache.size(-1) * 2;
  int num_heads = query.size(-1) / head_size;
  int num_kv_heads = key.size(-1) / head_size;
  int64_t query_stride = query.stride(-2);
  int64_t key_stride = key.stride(-2);

  dim3 grid(num_tokens);
  dim3 block(std::min<int64_t>(num_heads * rot_dim / 2, 512));
  const at::cuda::OptionalCUDAGuard device_guard(device_of(query));
  const cudaStream_t stream = at::cuda::getCurrentCUDAStream();
  VLLM_DISPATCH_FLOATING_TYPES(query.scalar_type(), "rotary_embedding", [&]
                               {
    if (is_neox) {
      if (is_nope_first)
      {
        vllm::rotary_embedding_kernel<scalar_t, true, true><<<grid, block, 0, stream>>>(
            positions.data_ptr<int64_t>(), query.data_ptr<scalar_t>(),
            key.data_ptr<scalar_t>(), cos_cache.data_ptr<scalar_t>(), sin_cache.data_ptr<scalar_t>(), rot_dim,
            query_stride, key_stride, num_heads, num_kv_heads, head_size);
      }
      else
      {
        vllm::rotary_embedding_kernel<scalar_t, true, false><<<grid, block, 0, stream>>>(
            positions.data_ptr<int64_t>(), query.data_ptr<scalar_t>(),
            key.data_ptr<scalar_t>(), cos_cache.data_ptr<scalar_t>(), sin_cache.data_ptr<scalar_t>(), rot_dim,
            query_stride, key_stride, num_heads, num_kv_heads, head_size);
      }
    } else {
      if (is_nope_first)
      {
        vllm::rotary_embedding_kernel<scalar_t, false, true><<<grid, block, 0, stream>>>(
            positions.data_ptr<int64_t>(), query.data_ptr<scalar_t>(),
            key.data_ptr<scalar_t>(), cos_cache.data_ptr<scalar_t>(), sin_cache.data_ptr<scalar_t>(), rot_dim,
            query_stride, key_stride, num_heads, num_kv_heads, head_size);
      }
      else
      {
        vllm::rotary_embedding_kernel<scalar_t, false, false><<<grid, block, 0, stream>>>(
            positions.data_ptr<int64_t>(), query.data_ptr<scalar_t>(),
            key.data_ptr<scalar_t>(), cos_cache.data_ptr<scalar_t>(), sin_cache.data_ptr<scalar_t>(), rot_dim,
            query_stride, key_stride, num_heads, num_kv_heads, head_size);
      }
      
    } });
}

/*
Batched version of rotary embedding, pack multiple LoRAs together
and process in batched manner.
*/
void batched_rotary_embedding(
    torch::Tensor &positions, // [batch_size, seq_len] or [num_tokens]
    torch::Tensor &query,     // [batch_size, seq_len, num_heads * head_size] or
                              // [num_tokens, num_heads * head_size]
    torch::Tensor &key,       // [batch_size, seq_len, num_kv_heads * head_size] or
                              // [num_tokens, num_kv_heads * head_size]
    int64_t head_size,
    torch::Tensor &cos_cache, // [max_position, rot_dim//2]
    torch::Tensor &sin_cache, // [max_position, rot_dim//2]
    bool is_neox, bool is_nope_first, int64_t rot_dim,
    torch::Tensor &cos_sin_cache_offsets // [num_tokens]
)
{
  int64_t num_tokens = cos_sin_cache_offsets.size(0);
  int num_heads = query.size(-1) / head_size;
  int num_kv_heads = key.size(-1) / head_size;
  int64_t query_stride = query.stride(-2);
  int64_t key_stride = key.stride(-2);

  dim3 grid(num_tokens);
  dim3 block(std::min<int64_t>(num_heads * rot_dim / 2, 512));
  const at::cuda::OptionalCUDAGuard device_guard(device_of(query));
  const cudaStream_t stream = at::cuda::getCurrentCUDAStream();
  VLLM_DISPATCH_FLOATING_TYPES(query.scalar_type(), "rotary_embedding", [&]
                               {
    if (is_neox) {
      if (is_nope_first)
      {
        vllm::batched_rotary_embedding_kernel<scalar_t, true, true>
            <<<grid, block, 0, stream>>>(
                positions.data_ptr<int64_t>(), query.data_ptr<scalar_t>(),
                key.data_ptr<scalar_t>(), cos_cache.data_ptr<scalar_t>(), sin_cache.data_ptr<scalar_t>(),
                cos_sin_cache_offsets.data_ptr<int64_t>(), rot_dim, query_stride,
                key_stride, num_heads, num_kv_heads, head_size);
      }
      else
      {
        vllm::batched_rotary_embedding_kernel<scalar_t, true, false>
            <<<grid, block, 0, stream>>>(
                positions.data_ptr<int64_t>(), query.data_ptr<scalar_t>(),
                key.data_ptr<scalar_t>(), cos_cache.data_ptr<scalar_t>(), sin_cache.data_ptr<scalar_t>(),
                cos_sin_cache_offsets.data_ptr<int64_t>(), rot_dim, query_stride,
                key_stride, num_heads, num_kv_heads, head_size);
      }
    } else {
      if (is_nope_first)
      {
        vllm::batched_rotary_embedding_kernel<scalar_t, false, true>
            <<<grid, block, 0, stream>>>(
                positions.data_ptr<int64_t>(), query.data_ptr<scalar_t>(),
                key.data_ptr<scalar_t>(), cos_cache.data_ptr<scalar_t>(), sin_cache.data_ptr<scalar_t>(),
                cos_sin_cache_offsets.data_ptr<int64_t>(), rot_dim, query_stride,
                key_stride, num_heads, num_kv_heads, head_size);
      }
      else
      {
        vllm::batched_rotary_embedding_kernel<scalar_t, false, false>
            <<<grid, block, 0, stream>>>(
                positions.data_ptr<int64_t>(), query.data_ptr<scalar_t>(),
                key.data_ptr<scalar_t>(), cos_cache.data_ptr<scalar_t>(), sin_cache.data_ptr<scalar_t>(),
                cos_sin_cache_offsets.data_ptr<int64_t>(), rot_dim, query_stride,
                key_stride, num_heads, num_kv_heads, head_size);
      }
    } });
}
