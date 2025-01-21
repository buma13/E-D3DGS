/*
 * Copyright (C) 2023, Inria
 * GRAPHDECO research group, https://team.inria.fr/graphdeco
 * All rights reserved.
 *
 * This software is free for non-commercial, research and evaluation use 
 * under the terms of the LICENSE.md file.
 *
 * For inquiries contact  george.drettakis@inria.fr
 */

#include "rasterizer_impl.h"
#include <iostream>
#include <fstream>
#include <algorithm>
#include <numeric>
#include <cuda.h>
#include "cuda_runtime.h"
#include "device_launch_parameters.h"
#include <cub/cub.cuh>
#include <cub/device/device_radix_sort.cuh>
#define GLM_FORCE_CUDA
#include <glm/glm.hpp>

#include <cooperative_groups.h>
#include <cooperative_groups/reduce.h>
namespace cg = cooperative_groups;

#include "auxiliary.h"
#include "forward.h"
#include "backward.h"

// Helper function to find the next-highest bit of the MSB
// on the CPU.
uint32_t getHigherMsb(uint32_t n)
{
	uint32_t msb = sizeof(n) * 4;
	uint32_t step = msb;
	while (step > 1)
	{
		step /= 2;
		if (n >> msb)
			msb += step;
		else
			msb -= step;
	}
	if (n >> msb)
		msb++;
	return msb;
}

// Wrapper method to call auxiliary coarse frustum containment test.
// Mark all Gaussians that pass it.
__global__ void checkFrustum(int P,
	const float* orig_points,
	const float* viewmatrix,
	const float* projmatrix,
	bool* present)
{
	auto idx = cg::this_grid().thread_rank();
	if (idx >= P)
		return;

	float3 p_view;
	present[idx] = in_frustum(idx, orig_points, viewmatrix, projmatrix, false, p_view);
}

// Generates one key/value pair for all Gaussian / tile overlaps. 
// Run once per Gaussian (1:N mapping).
__global__ void duplicateWithKeys(
	int P,
	const float2* points_xy,
	const float* depths,
	const uint32_t* offsets,
	uint64_t* gaussian_keys_unsorted,
	uint32_t* gaussian_values_unsorted,
	int* radii,
	dim3 grid)
{
	auto idx = cg::this_grid().thread_rank();
	if (idx >= P)
		return;

	// Generate no key/value pair for invisible Gaussians
	if (radii[idx] > 0)
	{
		// Find this Gaussian's offset in buffer for writing keys/values.
		uint32_t off = (idx == 0) ? 0 : offsets[idx - 1];
		uint2 rect_min, rect_max;

		getRect(points_xy[idx], radii[idx], rect_min, rect_max, grid);

		// For each tile that the bounding rect overlaps, emit a 
		// key/value pair. The key is |  tile ID  |      depth      |,
		// and the value is the ID of the Gaussian. Sorting the values 
		// with this key yields Gaussian IDs in a list, such that they
		// are first sorted by tile and then by depth. 
		for (int y = rect_min.y; y < rect_max.y; y++)
		{
			for (int x = rect_min.x; x < rect_max.x; x++)
			{
				uint64_t key = y * grid.x + x;
				key <<= 32;
				key |= *((uint32_t*)&depths[idx]);
				gaussian_keys_unsorted[off] = key;
				gaussian_values_unsorted[off] = idx;
				off++;
			}
		}
	}
}


__global__ void createWithKeys(
	int P,
	const float2* points_xy,
	const float* depths,
	const uint32_t* offsets,
	const uint32_t* tiles_touched,
	uint64_t* points_keys_unsorted,
	uint32_t* points_values_unsorted,
	dim3 grid)
{
	auto idx = cg::this_grid().thread_rank();
	if (idx >= P)
		return;

	// Generate no key/value pair for invisible Points
	if (tiles_touched[idx] > 0)
	{
		// Find this Point's offset in buffer for writing keys/values.
		uint32_t off = (idx == 0) ? 0 : offsets[idx - 1];
		
		// determine the tile that the point is in
		const float2 p = points_xy[idx];
		int x = min(grid.x - 1, max((int)0, (int)(p.x / BLOCK_X)));
		int y = min(grid.y - 1, max((int)0, (int)(p.y / BLOCK_Y)));
	
		uint64_t key = y * grid.x + x;
		key <<= 32;
		key |= *((uint32_t*)&depths[idx]);
		points_keys_unsorted[off] = key;
		points_values_unsorted[off] = idx;
	}
}


// Check keys to see if it is at the start/end of one tile's range in 
// the full sorted list. If yes, write start/end of this tile. 
// Run once per instanced (duplicated) Gaussian ID.
__global__ void identifyTileRanges(int L, uint64_t* point_list_keys, uint2* ranges)
{
	auto idx = cg::this_grid().thread_rank();
	if (idx >= L)
		return;

	// Read tile ID from key. Update start/end of tile range if at limit.
	uint64_t key = point_list_keys[idx];
	uint32_t currtile = key >> 32;
	if (idx == 0)
		ranges[currtile].x = 0;
	else
	{
		uint32_t prevtile = point_list_keys[idx - 1] >> 32;
		if (currtile != prevtile)
		{
			ranges[prevtile].y = idx;
			ranges[currtile].x = idx;
		}
	}
	if (idx == L - 1)
		ranges[currtile].y = L;
}

// Mark Gaussians as visible/invisible, based on view frustum testing
void CudaRasterizer::Rasterizer::markVisible(
	int P,
	float* means3D,
	float* viewmatrix,
	float* projmatrix,
	bool* present)
{
	checkFrustum << <(P + 255) / 256, 256 >> > (
		P,
		means3D,
		viewmatrix, projmatrix,
		present);
}

CudaRasterizer::GeometryState CudaRasterizer::GeometryState::fromChunk(char*& chunk, size_t P)
{
	GeometryState geom;
	obtain(chunk, geom.depths, P, 128);
	obtain(chunk, geom.camera_planes, P * 6, 128);
	obtain(chunk, geom.ray_planes, P, 128);
	obtain(chunk, geom.ts, P, 128);
	obtain(chunk, geom.normals, P, 128);
	obtain(chunk, geom.clamped, P * 3, 128);
	obtain(chunk, geom.internal_radii, P, 128);
	obtain(chunk, geom.means2D, P, 128);
	obtain(chunk, geom.view_points, P * 3, 128);
	obtain(chunk, geom.cov3D, P * 6, 128);
	obtain(chunk, geom.conic_opacity, P, 128);
	obtain(chunk, geom.rgb, P * 3, 128);
	obtain(chunk, geom.tiles_touched, P, 128);
	cub::DeviceScan::InclusiveSum(nullptr, geom.scan_size, geom.tiles_touched, geom.tiles_touched, P);
	obtain(chunk, geom.scanning_space, geom.scan_size, 128);
	obtain(chunk, geom.point_offsets, P, 128);
	return geom;
}

CudaRasterizer::PointState CudaRasterizer::PointState::fromChunk(char*& chunk, size_t P)
{
	PointState geom;
	obtain(chunk, geom.depths, P, 128);
	obtain(chunk, geom.points2D, P, 128);
	obtain(chunk, geom.tiles_touched, P, 128);
	cub::DeviceScan::InclusiveSum(nullptr, geom.scan_size, geom.tiles_touched, geom.tiles_touched, P);
	obtain(chunk, geom.scanning_space, geom.scan_size, 128);
	obtain(chunk, geom.point_offsets, P, 128);
	return geom;
}

CudaRasterizer::ImageState CudaRasterizer::ImageState::fromChunk(char*& chunk, size_t N)
{
	ImageState img;
	// obtain(chunk, img.accum_alpha, N * 4, 128);
	obtain(chunk, img.n_contrib, N * 2, 128);
	obtain(chunk, img.ranges, N, 128);
	obtain(chunk, img.point_ranges, N, 128);
	obtain(chunk, img.accum_coord, N * 3, 128);
	obtain(chunk, img.accum_depth, N, 128);
	obtain(chunk, img.normal_length, N, 128);
	return img;
}

CudaRasterizer::BinningState CudaRasterizer::BinningState::fromChunk(char*& chunk, size_t P)
{
	BinningState binning;
	obtain(chunk, binning.point_list, P, 128);
	obtain(chunk, binning.point_list_unsorted, P, 128);
	obtain(chunk, binning.point_list_keys, P, 128);
	obtain(chunk, binning.point_list_keys_unsorted, P, 128);
	cub::DeviceRadixSort::SortPairs(
		nullptr, binning.sorting_size,
		binning.point_list_keys_unsorted, binning.point_list_keys,
		binning.point_list_unsorted, binning.point_list, P);
	obtain(chunk, binning.list_sorting_space, binning.sorting_size, 128);
	return binning;
}

// Forward rendering procedure for differentiable rasterization
// of Gaussians.
int CudaRasterizer::Rasterizer::forward(
	std::function<char* (size_t)> geometryBuffer,
	std::function<char* (size_t)> binningBuffer,
	std::function<char* (size_t)> imageBuffer,
	const int P, int D, int M,
	const float* background,
	const int width, int height,
	const float* means3D,
	const float* shs,
	const float* colors_precomp,
	const float* opacities,
	const float* scales,
	const float scale_modifier,
	const float* rotations,
	const float* cov3D_precomp,
	const float* viewmatrix,
	const float* projmatrix,
	const float* cam_pos,
	const float tan_fovx, float tan_fovy,
	const float kernel_size,
	const bool prefiltered,
	float* out_color,
	float* out_coord,
	float* out_mcoord,
	float* out_depth,
	float* out_mdepth,
	float* out_alpha,
	float* out_normal,
	float* proj_2D,
	float* conic_2D,
	float* conic_2D_inv,
	float* gs_per_pixel,
	float* weight_per_gs_pixel,
	float* x_mu,
	int* radii,
	bool require_coord,
	bool require_depth,
	bool debug
	)
{
	const float focal_y = height / (2.0f * tan_fovy);
	const float focal_x = width / (2.0f * tan_fovx);

	size_t chunk_size = required<GeometryState>(P);
	char* chunkptr = geometryBuffer(chunk_size);
	GeometryState geomState = GeometryState::fromChunk(chunkptr, P);

	if (radii == nullptr)
	{
		radii = geomState.internal_radii;
	}

	dim3 tile_grid((width + BLOCK_X - 1) / BLOCK_X, (height + BLOCK_Y - 1) / BLOCK_Y, 1);
	dim3 block(BLOCK_X, BLOCK_Y, 1);

	// Dynamically resize image-based auxiliary buffers during training
	size_t img_chunk_size = required<ImageState>(width * height);
	char* img_chunkptr = imageBuffer(img_chunk_size);
	ImageState imgState = ImageState::fromChunk(img_chunkptr, width * height);

	if (NUM_CHANNELS != 3 && colors_precomp == nullptr)
	{
		throw std::runtime_error("For non-RGB, provide precomputed Gaussian colors!");
	}

	// Run preprocessing per-Gaussian (transformation, bounding, conversion of SHs to RGB)
	CHECK_CUDA(FORWARD::preprocess(
		P, D, M,
		means3D,
		(glm::vec3*)scales,
		scale_modifier,
		(glm::vec4*)rotations,
		opacities,
		shs,
		geomState.clamped,
		cov3D_precomp,
		colors_precomp,
		viewmatrix, projmatrix,
		(glm::vec3*)cam_pos,
		width, height,
		focal_x, focal_y,
		tan_fovx, tan_fovy,
		kernel_size,
		radii,
		geomState.means2D,
		(float3*)geomState.view_points,
		geomState.depths,
		geomState.camera_planes,
		geomState.ray_planes,
		geomState.ts,
		geomState.normals,
		proj_2D,
		conic_2D,
		conic_2D_inv,
		gs_per_pixel,
		weight_per_gs_pixel,
		geomState.cov3D,
		geomState.rgb,
		geomState.conic_opacity,
		tile_grid,
		geomState.tiles_touched,
		false,
		prefiltered
	), debug)

	// Compute prefix sum over full list of touched tile counts by Gaussians
	// E.g., [2, 3, 0, 2, 1] -> [2, 5, 5, 7, 8]
	CHECK_CUDA(cub::DeviceScan::InclusiveSum(geomState.scanning_space, geomState.scan_size, geomState.tiles_touched, geomState.point_offsets, P), debug)

	// Retrieve total number of Gaussian instances to launch and resize aux buffers
	int num_rendered;
	CHECK_CUDA(cudaMemcpy(&num_rendered, geomState.point_offsets + P - 1, sizeof(int), cudaMemcpyDeviceToHost), debug);

	size_t binning_chunk_size = required<BinningState>(num_rendered);
	char* binning_chunkptr = binningBuffer(binning_chunk_size);
	BinningState binningState = BinningState::fromChunk(binning_chunkptr, num_rendered);

	// For each instance to be rendered, produce adequate [ tile | depth ] key 
	// and corresponding dublicated Gaussian indices to be sorted
	duplicateWithKeys << <(P + 255) / 256, 256 >> > (
		P,
		geomState.means2D,
		geomState.depths,
		geomState.point_offsets,
		binningState.point_list_keys_unsorted,
		binningState.point_list_unsorted,
		radii,
		tile_grid)
	CHECK_CUDA(, debug)

	int bit = getHigherMsb(tile_grid.x * tile_grid.y);

	// Sort complete list of (duplicated) Gaussian indices by keys
	CHECK_CUDA(cub::DeviceRadixSort::SortPairs(
		binningState.list_sorting_space,
		binningState.sorting_size,
		binningState.point_list_keys_unsorted, binningState.point_list_keys,
		binningState.point_list_unsorted, binningState.point_list,
		num_rendered, 0, 32 + bit), debug)

	CHECK_CUDA(cudaMemset(imgState.ranges, 0, tile_grid.x * tile_grid.y * sizeof(uint2)), debug);

	// Identify start and end of per-tile workloads in sorted list
	if (num_rendered > 0)
		identifyTileRanges << <(num_rendered + 255) / 256, 256 >> > (
			num_rendered,
			binningState.point_list_keys,
			imgState.ranges);
	CHECK_CUDA(, debug);

	// Let each tile blend its range of Gaussians independently in parallel
	const float* feature_ptr = colors_precomp != nullptr ? colors_precomp : geomState.rgb;
	CHECK_CUDA(FORWARD::render(
		tile_grid, block,
		imgState.ranges,
		binningState.point_list,
		width, height,
		geomState.view_points,
		geomState.means2D,
		feature_ptr,
		geomState.ts,
		geomState.camera_planes,
		geomState.ray_planes,
		geomState.normals,
		geomState.conic_opacity,
		focal_x, focal_y,
		out_alpha,
		imgState.n_contrib,
		background,
		out_color,
		out_coord,
		out_mcoord,
		out_normal,
        proj_2D,
		conic_2D,
		gs_per_pixel,
		weight_per_gs_pixel,
		x_mu,
		out_depth,
		out_mdepth,
		imgState.accum_coord,
		imgState.accum_depth,
		imgState.normal_length,
		require_coord,
		require_depth), debug);

	return num_rendered;
}

// Produce necessary gradients for optimization, corresponding
// to forward render pass
void CudaRasterizer::Rasterizer::backward(
	const int P, int D, int M, int R,
	const float* background,
	const int width, int height,
	const float* means3D,
	const float* shs,
	const float* colors_precomp,
	const float* alphas,
	const float* scales,
	const float scale_modifier,
	const float* rotations,
	const float* cov3D_precomp,
	const float* viewmatrix,
	const float* projmatrix,
	const float* campos,
	const float tan_fovx, float tan_fovy,
	const float kernel_size,
	const int* radii,
	const float* normalmap,
	char* geom_buffer,
	char* binning_buffer,
	char* img_buffer,
	const float* dL_dpix,
	const float* dL_dpix_coord,
	const float* dL_dpix_mcoord,
	const float* dL_dpix_depth,
	const float* dL_dpix_mdepth,
	const float* dL_dalphas,
	const float* dL_dpixel_normals,
	float* dL_dmean2D,
	float* dL_dview_points,
	float* dL_dconic,
	float* dL_dopacity,
	float* dL_dcolor,
	float* dL_dts,
	float* dL_dcamera_planes,
	float* dL_dray_planes,
	float* dL_dnormals,
	float* dL_proj_2D,
	float* dL_conic_2D,
	float* dL_conic_2D_inv,
	float* dummy_gs_per_pixel,
	float* dummy_weight_per_gs_pixel,
	float* grad_x_mu,
	float* dL_dmean3D,
	float* dL_dcov3D,
	float* dL_dsh,
	float* dL_dscale,
	float* dL_drot,
	bool require_coord,
	bool require_depth,
	bool debug)
{
	GeometryState geomState = GeometryState::fromChunk(geom_buffer, P);
	BinningState binningState = BinningState::fromChunk(binning_buffer, R);
	ImageState imgState = ImageState::fromChunk(img_buffer, width * height);

	if (radii == nullptr)
	{
		radii = geomState.internal_radii;
	}

	const float focal_y = height / (2.0f * tan_fovy);
	const float focal_x = width / (2.0f * tan_fovx);

	const dim3 tile_grid((width + BLOCK_X - 1) / BLOCK_X, (height + BLOCK_Y - 1) / BLOCK_Y, 1);
	const dim3 block(BLOCK_X, BLOCK_Y, 1);

	// Compute loss gradients w.r.t. 2D mean position, conic matrix,
	// opacity and RGB of Gaussians from per-pixel loss gradients.
	// If we were given precomputed colors and not SHs, use them.
	const float* color_ptr = (colors_precomp != nullptr) ? colors_precomp : geomState.rgb;
	CHECK_CUDA(BACKWARD::render(
		tile_grid,
		block,
		imgState.ranges,
		binningState.point_list,
		width, height,
		background,
		geomState.view_points,
		geomState.means2D,
		geomState.conic_opacity,
		color_ptr,
		geomState.depths,
		geomState.ts,
		geomState.camera_planes,
		geomState.ray_planes,
		alphas,
		geomState.normals,
		imgState.accum_coord,
		imgState.accum_depth,
		imgState.normal_length,
		imgState.n_contrib,
		dL_dpix,
		dL_dpix_coord,
		dL_dpix_mcoord,
		dL_dpix_depth,
		dL_dpix_mdepth,
		dL_dalphas,
		dL_dpixel_normals,
		normalmap,
		focal_x, focal_y,
		(float3*)dL_dview_points,
		(float3*)dL_dmean2D,
		(float4*)dL_dconic,
		dL_dopacity,
		dL_dcolor,
		dL_dts,
		dL_dcamera_planes,
		(float2*)dL_dray_planes,
		dL_dnormals,
		dL_proj_2D,
		dL_conic_2D,
		dL_conic_2D_inv,
		dummy_gs_per_pixel,
		dummy_weight_per_gs_pixel,
		grad_x_mu,
		require_coord,
		require_depth), debug)

	// Take care of the rest of preprocessing. Was the precomputed covariance
	// given to us or a scales/rot pair? If precomputed, pass that. If not,
	// use the one we computed ourselves.
	const float* cov3D_ptr = (cov3D_precomp != nullptr) ? cov3D_precomp : geomState.cov3D;
	CHECK_CUDA(BACKWARD::preprocess(P, D, M,
		(float3*)means3D,
		radii,
		shs,
		geomState.clamped,
		(glm::vec3*)scales,
		(glm::vec4*)rotations,
		scale_modifier,
		cov3D_ptr,
		viewmatrix,
		projmatrix,
		focal_x, focal_y,
		tan_fovx, tan_fovy,
		kernel_size,
		(glm::vec3*)campos,
		(float3*)dL_dmean2D,
		dL_dconic,
		(float3*)dL_dview_points,
		(glm::vec3*)dL_dmean3D,
		dL_dcolor,
		dL_dts,
		(float2*)dL_dcamera_planes,
		(float2*)dL_dray_planes,
		dL_dnormals,
		dL_proj_2D,
		dL_conic_2D,
		dL_conic_2D_inv,
		dummy_gs_per_pixel,
		dummy_weight_per_gs_pixel,
		grad_x_mu,
		dL_dcov3D,
		dL_dsh,
		(glm::vec3*)dL_dscale,
		(glm::vec4*)dL_drot,
		(float4*)dL_dconic,
		dL_dopacity), debug)
}

int CudaRasterizer::Rasterizer::integrate(
	std::function<char* (size_t)> geometryBuffer,
	std::function<char* (size_t)> binningBuffer,
	std::function<char* (size_t)> imageBuffer,
	std::function<char* (size_t)> pointBuffer,
	std::function<char* (size_t)> point_binningBuffer,
	const int PN, const int P, int D, int M,
	const float* background,
	const int width, int height,
	const float* points3D,
	const float* means3D,
	const float* shs,
	const float* colors_precomp,
	const float* opacities,
	const float* scales,
	const float scale_modifier,
	const float* rotations,
	const float* cov3D_precomp,
	const float* depths_plane_precomp,
	const float* viewmatrix,
	const float* projmatrix,
	const float* cam_pos,
	const float tan_fovx, float tan_fovy,
	const float kernel_size,
	const float* subpixel_offset,
	const bool prefiltered,
	float* out_color,
	float* accum_alpha,
	float* invraycov3Ds,
	float* proj_2D,
	float* conic_2D,
	float* conic_2D_inv,
	float* gs_per_pixel,
	float* weight_per_gs_pixel,
	float* x_mu,
	int* radii, // remove 
	float* out_alpha_integrated,
	float* out_color_integrated,
	float* out_coordinate2d,
	float* out_sdf,
	bool* condition,
	bool debug)
{
	const float focal_y = height / (2.0f * tan_fovy);
	const float focal_x = width / (2.0f * tan_fovx);

	size_t chunk_size = required<GeometryState>(P);
	char* chunkptr = geometryBuffer(chunk_size);
	GeometryState geomState = GeometryState::fromChunk(chunkptr, P);

	if (radii == nullptr)
	{
		radii = geomState.internal_radii;
	}

	dim3 tile_grid((width + BLOCK_X - 1) / BLOCK_X, (height + BLOCK_Y - 1) / BLOCK_Y, 1);
	dim3 block(BLOCK_X, BLOCK_Y, 1);

	// Dynamically resize image-based auxiliary buffers during training
	size_t img_chunk_size = required<ImageState>(width * height);
	char* img_chunkptr = imageBuffer(img_chunk_size);
	ImageState imgState = ImageState::fromChunk(img_chunkptr, width * height);

	if (NUM_CHANNELS != 3 && colors_precomp == nullptr)
	{
		throw std::runtime_error("For non-RGB, provide precomputed Gaussian colors!");
	}

	// Run preprocessing per-Gaussian (transformation, bounding, conversion of SHs to RGB)
	CHECK_CUDA(FORWARD::preprocess(
		P, D, M,
		means3D,
		(glm::vec3*)scales,
		scale_modifier,
		(glm::vec4*)rotations,
		opacities,
		shs,
		geomState.clamped,
		cov3D_precomp,
		colors_precomp,
		viewmatrix, projmatrix,
		(glm::vec3*)cam_pos,
		width, height,
		focal_x, focal_y,
		tan_fovx, tan_fovy,
		kernel_size,
		radii,
		geomState.means2D,
		(float3*)geomState.view_points,
		geomState.depths,
		geomState.camera_planes,
		geomState.ray_planes,
		geomState.ts,
		geomState.normals,
		proj_2D,
		conic_2D,
		conic_2D_inv,
		gs_per_pixel,
		weight_per_gs_pixel,
		geomState.cov3D,
		geomState.rgb,
		geomState.conic_opacity,
		tile_grid,
		geomState.tiles_touched,
		prefiltered,
		true,
		invraycov3Ds,
		condition
	), debug)

	

	// Compute prefix sum over full list of touched tile counts by Gaussians
	// E.g., [2, 3, 0, 2, 1] -> [2, 5, 5, 7, 8]
	CHECK_CUDA(cub::DeviceScan::InclusiveSum(geomState.scanning_space, geomState.scan_size, geomState.tiles_touched, geomState.point_offsets, P), debug)

	// Retrieve total number of Gaussian instances to launch and resize aux buffers
	int num_rendered;
	CHECK_CUDA(cudaMemcpy(&num_rendered, geomState.point_offsets + P - 1, sizeof(int), cudaMemcpyDeviceToHost), debug);

	size_t binning_chunk_size = required<BinningState>(num_rendered);
	char* binning_chunkptr = binningBuffer(binning_chunk_size);
	BinningState binningState = BinningState::fromChunk(binning_chunkptr, num_rendered);

	// For each instance to be rendered, produce adequate [ tile | depth ] key 
	// and corresponding dublicated Gaussian indices to be sorted
	duplicateWithKeys << <(P + 255) / 256, 256 >> > (
		P,
		geomState.means2D,
		geomState.depths,
		geomState.point_offsets,
		binningState.point_list_keys_unsorted,
		binningState.point_list_unsorted,
		radii,
		tile_grid)
	CHECK_CUDA(, debug)

	int bit = getHigherMsb(tile_grid.x * tile_grid.y);

	// Sort complete list of (duplicated) Gaussian indices by keys
	CHECK_CUDA(cub::DeviceRadixSort::SortPairs(
		binningState.list_sorting_space,
		binningState.sorting_size,
		binningState.point_list_keys_unsorted, binningState.point_list_keys,
		binningState.point_list_unsorted, binningState.point_list,
		num_rendered, 0, 32 + bit), debug)

	CHECK_CUDA(cudaMemset(imgState.ranges, 0, tile_grid.x * tile_grid.y * sizeof(uint2)), debug);

	// Identify start and end of per-tile workloads in sorted list
	if (num_rendered > 0)
		identifyTileRanges << <(num_rendered + 255) / 256, 256 >> > (
			num_rendered,
			binningState.point_list_keys,
			imgState.ranges);
	CHECK_CUDA(, debug)

	/**************************************** Integrate ****************************************/
	// create a list of points similar to the list of gaussians
	size_t point_chunk_size = required<PointState>(PN);
	char* point_chunkptr = pointBuffer(point_chunk_size);
	PointState pointState = PointState::fromChunk(point_chunkptr, PN);

	// Run preprocessing per-Point (transformation)
	CHECK_CUDA(FORWARD::preprocess_points(
		PN, D, M,
		points3D,
		viewmatrix, projmatrix,
		(glm::vec3*)cam_pos,
		width, height,
		focal_x, focal_y,
		tan_fovx, tan_fovy,
		pointState.points2D,
		pointState.depths,
		tile_grid,
		pointState.tiles_touched,
		prefiltered
	), debug)

	// Compute prefix sum over full list of touched tile counts by Gaussians
	// E.g., [2, 3, 0, 2, 1] -> [2, 5, 5, 7, 8]
	CHECK_CUDA(cub::DeviceScan::InclusiveSum(pointState.scanning_space, pointState.scan_size, pointState.tiles_touched, pointState.point_offsets, PN), debug)
	
	// Retrieve total number of Point instances to launch and resize aux buffers
	int num_integrated;
	CHECK_CUDA(cudaMemcpy(&num_integrated, pointState.point_offsets + PN - 1, sizeof(int), cudaMemcpyDeviceToHost), debug);

	size_t point_binning_chunk_size = required<BinningState>(num_integrated);
	char* point_binning_chunkptr = point_binningBuffer(point_binning_chunk_size);
	BinningState point_binningState = BinningState::fromChunk(point_binning_chunkptr, num_integrated);

	// if (DEBUG_INTEGRATE && PRINT_INTEGRATE_INFO){
	// 	printf("in CudaRasterizer::Rasterizer::integrate, PN: %d num_integrated: %d point_binning_chunk_size: %d\n", PN, num_integrated, point_binning_chunk_size);
	// 	// for (int i = 0; i < 100; i++){
	// 	// 	printf("pointState.tiles_touched[%d]: %d\n", i, (int)pointState.tiles_touched[i], (int)pointState.point_offsets[i]);
	// 	// }
	// 	// for (int i = PN-100; i < PN; i++){
	// 	// 	printf("pointState.tiles_touched[%d]: %d\n", i, pointState.tiles_touched[i], pointState.point_offsets[i]);
	// 	// }
	// }
	
	// For each point to be integrated, produce adequate [ tile | depth ] key 
	// and corresponding Point indices to be sorted
	createWithKeys << <(PN + 255) / 256, 256 >> > (
		PN,
		pointState.points2D,
		pointState.depths,
		pointState.point_offsets,
		pointState.tiles_touched,
		point_binningState.point_list_keys_unsorted,
		point_binningState.point_list_unsorted,
		tile_grid)
	CHECK_CUDA(, debug)

	//TODO: why we use num_integrated here?
	// Sort complete list of (duplicated) Gaussian indices by keys
	CHECK_CUDA(cub::DeviceRadixSort::SortPairs(
		point_binningState.list_sorting_space,
		point_binningState.sorting_size,
		point_binningState.point_list_keys_unsorted, point_binningState.point_list_keys,
		point_binningState.point_list_unsorted, point_binningState.point_list,
		num_integrated, 0, 32 + bit), debug)
	
	// if (DEBUG_INTEGRATE && PRINT_INTEGRATE_INFO){
	// 	printf("in CudaRasterizer::Rasterizer::integrate, after my sorting num_integrated: %d point_binning_chunk_size: %d\n", num_integrated, point_binning_chunk_size);
	// }
	
	CHECK_CUDA(cudaMemset(imgState.point_ranges, 0, tile_grid.x * tile_grid.y * sizeof(uint2)), debug);
	
	// Identify start and end of per-tile workloads in sorted list
	if (num_integrated > 0)
		identifyTileRanges << <(num_integrated + 255) / 256, 256 >> > (
			num_integrated,
			point_binningState.point_list_keys,
			imgState.point_ranges);
	CHECK_CUDA(, debug)
	
	// if (DEBUG_INTEGRATE && PRINT_INTEGRATE_INFO){
	// 	printf("in CudaRasterizer::Rasterizer::integrate, after my sorting num_integrated: %d point_binning_chunk_size: %d\n", num_integrated, point_binning_chunk_size);
	// 	// printf("imgState.point_ranges[0] = %d %d\n", imgState.point_ranges[0].x, imgState.point_ranges[0].y);
	// }
	
	// Let each tile blend its range of Gaussians independently in parallel
	const float* feature_ptr = colors_precomp != nullptr ? colors_precomp : geomState.rgb;
	const float* cov3Ds = cov3D_precomp != nullptr ? cov3D_precomp : geomState.cov3D;
	// const float* view2gaussian = view2gaussian_precomp;
	CHECK_CUDA(FORWARD::integrate(
		tile_grid, block,
		imgState.ranges,
		imgState.point_ranges,
		binningState.point_list,
		point_binningState.point_list,
		width, height,
		focal_x, focal_y,
		(float2*)subpixel_offset,
		pointState.points2D,
		geomState.means2D,
		feature_ptr,
		geomState.camera_planes,
		geomState.ray_planes,
		cov3Ds,
		viewmatrix,
		(float3*)points3D,
		(float3*)means3D,
		(float3*)scales,
		invraycov3Ds,
		pointState.depths,
		geomState.ts,
		geomState.conic_opacity,
		condition,
		accum_alpha,
		imgState.n_contrib,
		// imgState.center_depth,
		// imgState.center_alphas,
		background,
		out_color,
		out_alpha_integrated,
		out_color_integrated,
		out_coordinate2d,
		out_sdf), debug)

	return num_rendered;
}
