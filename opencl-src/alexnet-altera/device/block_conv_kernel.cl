#define BLOCK_SIZE	16
#define MAX_KERNEL_SIZE	11
#define K 3

/* Single work item kernel is giving max of 1600MB/s BW. and was taking ~16% of the total logic utilization
 * Now trying with 4 work items
 *
 *
 */
// stride is taken to be 1. If the required stride is not 1, then do conv with stride = 1 and do downsampling.
#if 0
__kernel
__attribute((reqd_work_group_size(BLOCK_SIZE, BLOCK_SIZE, 1)))

__attribute((num_simd_work_items(4)))
// TODO:Extend work group in z dimension of 2 dim works to share the same input data.
void block_3d_conv(
	__global float * restrict p_maps,
	__global float * restrict p_weights,
	__global float * restrict p_bias,
	__global float * restrict p_output,
	int no_inputs, int H, int W, int ker_size) {

	// local storage for one block of one input map. Extra rows and columns for padding area.
	__local float map_blk[BLOCK_SIZE + MAX_KERNEL_SIZE - 1][BLOCK_SIZE + MAX_KERNEL_SIZE - 1];
	// local buffer for weights corresponding to 1 map.
	__local float map_ker[MAX_KERNEL_SIZE][MAX_KERNEL_SIZE];

	// output block index of a block of one output map
	int block_x = get_group_id(0);
	int block_y = get_group_id(1);

	// output map pixel offset within block
	int local_x = get_local_id(0);
	int local_y = get_local_id(1);
	// current output map
	int out_map = get_global_id(2);

	// bias unit for this output map which is common to all work items
	__local float local_bias;
   	local_bias = p_bias[out_map];

	// block start location in each input map
	int row_start = block_y * BLOCK_SIZE * W;
	int col_start = block_x * BLOCK_SIZE;
	int K = ker_size & 0x0F;

	float sum = 0.0f;
	float zero = 0.0f;
	int filter_start = out_map * K * K * no_inputs;
	const bool copy_ker = ((local_x < K) && (local_y < K));

	// work items in the last column of the block will copy K-1 extra column pixels.
	const bool copy_extra_cols = (local_x == (BLOCK_SIZE-1));
	// first K-1 work items in the last row of the block will copy an extra row of size = BLOCK_SIZE
	const bool copy_extra_row = ((local_y == BLOCK_SIZE-1) && local_x < (K-1));
	int extra_row_idx = BLOCK_SIZE-1 + K - 1 - local_x;
	// NOTE: assuming BLOCK_SIZE > K-1, above two flags will not be true at the same time. 

	for(int imap = 0; imap < no_inputs; imap++) {
		// pointer to this input map in global memory
		global float *p_imap = p_maps + imap * H * W;

		// copy block of input map to local buffer
		//
		// copy one pixel from respective location
		if(copy_extra_row) {
			// copy pixel under this (x,y) location
			map_blk[local_y][local_x] = p_imap[row_start + local_y * W + col_start + local_x];
			// copy extra row assigned to this work item
			#pragma unroll
			for(int p = 0; p < BLOCK_SIZE; p++) {
				map_blk[extra_row_idx][p] = p_imap[row_start + extra_row_idx * W + col_start + p];
			}
		} else if(copy_extra_cols) {
			// copy K-1 extra columns incluidng pixel (x,y) under this work item
			#pragma unroll 3
			for(int c = 0; c < K; c++) {
				map_blk[local_y][local_x + c] = p_imap[row_start + local_y * W + col_start + local_x + c];
			}
		} else {
			// this work item only need to copy pixel (x,y) which is under its own position.
			map_blk[local_y][local_x] = p_imap[row_start + local_y * W + col_start + local_x];
		}

		// copy kernel for input map
		if(copy_ker) {
			map_ker[local_y][local_x] = p_weights[filter_start + (imap * K + local_y) * K + local_x];
		}

		barrier(CLK_LOCAL_MEM_FENCE);

		// compute
		#pragma unroll 3
		for(int kr = 0; kr < K; kr++) {
			#pragma unroll 3
			for(int kc = 0; kc < K; kc++) {
				sum += map_ker[kr][kc] * map_blk[local_y + kr][local_x + kc];
			}
		}	
		// wait for all work items to finish before overwriting local buffer.
		barrier(CLK_LOCAL_MEM_FENCE);
	}
	// add bias unit and write back
	sum += local_bias;
	p_output[(out_map * get_global_size(1) + get_global_id(1)) * get_global_size(0) + get_global_id(0)] = fmax(zero, sum);
}
#endif
/* This kernel uses block based convolution as above kernel. In the above kernel, the data is shared only between work items 
 * corresponding to 1 map. However, the input data is common across all output maps. In this kernel, the input map block is shared between
 * a group of output maps make better reuse of the data. Hence the required work group size is extended to z dimension.
 */
#if 1
#define NO_LOCAL_OUTPUT_MAPS	8
__kernel
__attribute((reqd_work_group_size(BLOCK_SIZE, BLOCK_SIZE, NO_LOCAL_OUTPUT_MAPS)))
__attribute((num_simd_work_items(4)))
void block_3d_conv(
	__global float * restrict p_maps
	, __global float * restrict p_weights
	, __global float * restrict p_bias
	, __global float * restrict p_output
	, int no_inputs
	, int H
	, int W
	) {

	// local storage for one block of one input map. Extra rows and columns for padding area.
	//__local float __attribute((memory, numbanks(8), bankwidth(64), doublepump))
	// __local float __attribute__((numbanks(8), bankwidth(4))) map_blk[2*BLOCK_SIZE][2*BLOCK_SIZE];
	__local float map_blk[2*BLOCK_SIZE][2*BLOCK_SIZE];
	// local buffer for weights corresponding to 1 input map. One KxK kernel for each output map
	//__local float __attribute((memory, numbanks(8), bankwidth(64), doublepump))
	//__local float __attribute__((numbanks(8), bankwidth(4))) map_ker[NO_LOCAL_OUTPUT_MAPS][BLOCK_SIZE/2][BLOCK_SIZE/2];
	__local float map_ker[NO_LOCAL_OUTPUT_MAPS][BLOCK_SIZE][BLOCK_SIZE];
	//__local float map_ker[NO_LOCAL_OUTPUT_MAPS][BLOCK_SIZE];

	// output block index of a block of a set of output map
	int block_x = get_group_id(0);
	int block_y = get_group_id(1);
	int block_z = get_group_id(2);

	// output map pixel offset within block
	int local_x = get_local_id(0);
	int local_y = get_local_id(1);
	int local_z = get_local_id(2);

	int gx = get_global_id(0);
	int gy = get_global_id(1);
	int gsx = get_global_size(0);
	int gsy = get_global_size(1);
//	int K = ker_size & 0xF;
	// current output map
	int out_map = get_global_id(2) & 0x1FF;		// we are not going to have more than 512 maps

	// bias unit for this output map which is common to all work items
	__local float local_bias[NO_LOCAL_OUTPUT_MAPS];

	// block start location in each input map
	int row_start = block_y * (BLOCK_SIZE-K+1) * W;
	int col_start = block_x * (BLOCK_SIZE-K+1);

	float sum = 0.0f;
	float zero = 0.0f;
	
	//int filter_start = out_map * K * K * no_inputs;
	// set a flag if this work item is entitled to copy a weight coefficient.
	//const bool copy_ker = ((local_x < K) && (local_y < K));
	// Let the work items in the center of the block in each plane copy the bias
	// as the workload on these items is less.
	const bool copy_bias = ((local_x == BLOCK_SIZE/2) && (local_y == BLOCK_SIZE/2));
	//const bool copy_bias = (local_x == 0 && local_y == 0);
	// first few work items in z=0 plane will copy 1 column on the block
	//const bool copy_col = (local_z == 0 && (local_y * BLOCK_SIZE + local_x) < (BLOCK_SIZE + K - 1));
	//int col_idx = local_y * BLOCK_SIZE + local_x;
	if(copy_bias) {
		local_bias[local_z] = p_bias[out_map];
	}
	//async_work_group_copy(local_bias, p_bias, NO_LOCAL_OUTPUT_MAPS, 0);

	for(uint imap = 0; imap < no_inputs; imap++) {
		//event_t events[2];
		// pointer to this input map in global memory
		global float *p_imap = p_maps + imap * H * W;
		/*if(copy_col) {
			#pragma unroll
			for(uint p = 0; p < BLOCK_SIZE + K - 1; p++) {
				//map_blk[p][col_idx] = p_imap[row_start + row_idx * W + col_start + p];
				map_blk[p][col_idx] = p_imap[row_start + p*W + col_start + col_idx];
			}
		}*/
		/*int lg_id = (local_z * BLOCK_SIZE + local_y) * BLOCK_SIZE + local_x;
		bool copy_pix = (lg_id < ((BLOCK_SIZE + K - 1) * (BLOCK_SIZE + K - 1)));
		int local_row = lg_id / (BLOCK_SIZE + K - 1);
		int local_col = lg_id % (BLOCK_SIZE + K - 1);
		if(copy_pix) {
			map_blk[local_row][local_col] = p_imap[row_start + local_row * W + col_start + local_col];
		}*/
		map_blk[local_y][local_x] = p_imap[row_start + local_y * W + col_start + local_x];
		/*for(int br = 0; br < BLOCK_SIZE+K-1; br++) {
			events[0] = async_work_group_copy(map_blk[br], p_imap + row_start + br*W + col_start,  BLOCK_SIZE + K - 1, 0);
		}*/
		// copy kernel for input map
		bool copy_ker = ((local_x < K) && (local_y < K));
		int filter_start = out_map * K * K * no_inputs;
		if(copy_ker) {
			map_ker[local_z][local_y][local_x] = p_weights[filter_start + (imap * K + local_y) * K + local_x];
		}
		/*int omap_ker = block_z * NO_LOCAL_OUTPUT_MAPS;
		for(int mk = 0; mk < NO_LOCAL_OUTPUT_MAPS; mk++) {
			events[1] = async_work_group_copy(map_ker[mk], p_weights + (omap_ker + mk) * K * K * no_inputs + imap * K * K, K*K, 0);
		}
	 	wait_group_events(2, events);*/
		barrier(CLK_LOCAL_MEM_FENCE);

		// compute
		#pragma unroll
		for(int kr = 0; kr < K; kr++) {
			#pragma unroll
			for(int kc = 0; kc < K; kc++) {
				sum += map_ker[local_z][kr][kc] * map_blk[local_y + kr][local_x + kc];
			}
		}

		/*#pragma unroll
		for(int k = 0; k < K*K; k++) {
			sum += map_ker[local_z][k] * map_blk[local_y + k/K][local_x + k%K];
		}*/
		// wait for all work items to finish before overwriting local buffer.
		barrier(CLK_LOCAL_MEM_FENCE);
	}
	// add bias unit and write back
	sum += local_bias[local_z];
	
	//p_output[(out_map * gsy + gy) * gsx + gx] = fmax(zero, sum);
	sum = fmax(zero, sum);
	bool write_pix = (local_y < (BLOCK_SIZE-K+1) && local_x < (BLOCK_SIZE-K+1));
	if(write_pix) {
		int oH = H - K + 1;
		int oW = W - K + 1;
		int out_row = block_y * (BLOCK_SIZE-K+1) + local_y;
		int out_col = block_x * (BLOCK_SIZE-K+1) + local_x;
		p_output[(out_map * oH + out_row)*oW + out_col] = sum;
	}
}
#endif

/*
 * This implementation reads input maps of 4 times the block size to evenly distrubute the read among all work items.
 * - cache is not implemented for input maps.
 * - map_blk is implemented with 32 banks. 18 reads 16 writes
 * - 84ms for conv3, map read burst size = 5, BW of DDR bank1(map read and write) 11650MB/s with 42% efficiency
 * - max stall 30.8%, 35% read occupancy
 */
#if 0
#define NO_LOCAL_OUTPUT_MAPS	8
__kernel
__attribute((reqd_work_group_size(BLOCK_SIZE, BLOCK_SIZE, NO_LOCAL_OUTPUT_MAPS)))
__attribute((num_simd_work_items(4)))
void block_3d_conv(
	__global float * restrict p_maps
	, __global float * restrict p_weights
	, __global float * restrict p_bias
	, __global float * restrict p_output
	, int no_inputs
	, int H
	, int W
	) {

	// local storage for one block of one input map. Extra rows and columns for padding area.
	//__local float __attribute((memory, numbanks(8), bankwidth(64), doublepump))
	// __local float __attribute__((numbanks(8), bankwidth(4))) map_blk[2*BLOCK_SIZE][2*BLOCK_SIZE];
	__local float map_blk[NO_LOCAL_OUTPUT_MAPS][2*BLOCK_SIZE][2*BLOCK_SIZE];
	// local buffer for weights corresponding to 1 input map. One KxK kernel for each output map
	//__local float __attribute((memory, numbanks(8), bankwidth(64), doublepump))
	//__local float __attribute__((numbanks(8), bankwidth(4))) map_ker[NO_LOCAL_OUTPUT_MAPS][BLOCK_SIZE/2][BLOCK_SIZE/2];
	__local float map_ker[NO_LOCAL_OUTPUT_MAPS][NO_LOCAL_OUTPUT_MAPS][BLOCK_SIZE][BLOCK_SIZE];

	// output block index of a block of a set of output map
	int block_x = get_group_id(0);
	int block_y = get_group_id(1);
	int block_z = get_group_id(2);

	// output map pixel offset within block
	int local_x = get_local_id(0);
	int local_y = get_local_id(1);
	int local_z = get_local_id(2);

	int gx = get_global_id(0);
	int gy = get_global_id(1);
	int gsx = get_global_size(0);
	int gsy = get_global_size(1);

	// current output map
	int out_map = get_global_id(2) & 0x1FF;		// we are not going to have more than 512 maps

	// block start location in each input map
	int row_start = block_y * BLOCK_SIZE * W;
	int col_start = block_x * BLOCK_SIZE;

	float sum = 0.0f;
	float zero = 0.0f;
	
	const bool copy_ker = ((local_x < K) && (local_y < K));
	// for this to be functionally correct, no of input maps must be multiple for NO_LOCAL_OUTPUT_MAPS
	for(uint imap = 0; imap < no_inputs; imap+=NO_LOCAL_OUTPUT_MAPS) {
		// pointer to this input map in global memory
		global float * cur_ptr = p_maps + (imap+local_z) * H * W +  row_start + (2*local_y + (local_x >> 3)) * W + col_start;
		map_blk[local_z][2*local_y + (local_x >> 3)][4*(local_x % 8) + 0] = cur_ptr[4*(local_x % 8) + 0];
		map_blk[local_z][2*local_y + (local_x >> 3)][4*(local_x % 8) + 1] = cur_ptr[4*(local_x % 8) + 1];
		map_blk[local_z][2*local_y + (local_x >> 3)][4*(local_x % 8) + 2] = cur_ptr[4*(local_x % 8) + 2];
		map_blk[local_z][2*local_y + (local_x >> 3)][4*(local_x % 8) + 3] = cur_ptr[4*(local_x % 8) + 3];
		// copy kernel for NO_LOCAL_OUTPUT_MAPS input maps
		#pragma unroll
		for(int ker = 0; ker < NO_LOCAL_OUTPUT_MAPS; ker++) {
			int filter_start = out_map * K * K * no_inputs + (imap+ker) * K * K;
			if(copy_ker) {
				map_ker[local_z][ker][local_y][local_x] = p_weights[filter_start + local_y * K + local_x];
			}
		}
		barrier(CLK_LOCAL_MEM_FENCE);
		for(int in = 0; in < NO_LOCAL_OUTPUT_MAPS; in++) {
			// compute
			#pragma unroll
			for(int kr = 0; kr < K; kr++) {
				#pragma unroll
				for(int kc = 0; kc < K; kc++) {
					sum += map_ker[local_z][in][kr][kc] * map_blk[in][local_y + kr][local_x + kc];
				}
			}
		}

		// wait for all work items to finish before overwriting local buffer.
		barrier(CLK_LOCAL_MEM_FENCE);
	}
	// add bias unit and write back
	sum += p_bias[out_map];
	p_output[(out_map * gsy + gy) * gsx + gx] = fmax(zero, sum);
}
#endif
/*
 * conv3: 37ms
 * weight read 440MB/s, input read 18.6MB/s, 183.5MHz
 * all burst size = 1
 * weight read stall 8.3%
 */
#if 0
#define NO_LOCAL_OUTPUT_MAPS	16
__kernel
__attribute((reqd_work_group_size(BLOCK_SIZE, 2, NO_LOCAL_OUTPUT_MAPS)))
__attribute((num_simd_work_items(4)))
void block_3d_conv(
	__global float * restrict p_maps
	, __global float * restrict p_weights
	, __global float * restrict p_bias
	, __global float * restrict p_output
	, int no_inputs
	, int H
	, int W
	) {

	__local float map_blk[2*BLOCK_SIZE][2*BLOCK_SIZE];
	__local float map_ker[NO_LOCAL_OUTPUT_MAPS][BLOCK_SIZE][BLOCK_SIZE];
	
	// window register to buffer data and kernel
	float win_data[K][K];
	float win_ker[K][K];

	// output block index of a block of a set of output map
	int block_x = get_group_id(0); // [0...BLOCK_SIZE)
	int block_y = get_group_id(1); // [0...1]
	int block_z = get_group_id(2); // [0...NO_LOCAL_OUTPUT_MAPS)

	// output map pixel offset within block
	int local_x = get_local_id(0);
	int local_y = get_local_id(1);
	int local_z = get_local_id(2);

	int gx = get_global_id(0);
	int gy = get_global_id(1);
	int gsx = get_global_size(0);
	int gsy = get_global_size(1);

	// current output map
	int out_map = get_global_id(2) & 0x1FF;		// we are not going to have more than 512 maps

	// bias unit for this output map which is common to all work items
	__local float local_bias[NO_LOCAL_OUTPUT_MAPS];

	// block start location in each input map
	int row_start = block_y * BLOCK_SIZE * W;
	int col_start = block_x * BLOCK_SIZE;

	float sum[BLOCK_SIZE/2];
	for(int acc = 0; acc < BLOCK_SIZE/2; acc++) {
		sum[acc] = 0.0f;
	}
	float zero = 0.0f;
	
	int filter_start = out_map * K * K * no_inputs;
	// set a flag if this work item is entitled to copy a weight coefficient.
	// first K work items in row 0 of each plane will copy one column of the filter.
	// This is assuming that K <= BLOCK_SIZE
	const bool copy_ker = (local_y == 0 && local_x < K);

	// first work item in each plane will copy corresponding bias unit.
	const bool copy_bias = ((local_x == 0) && (local_y == 0));
	
	// first few work items in z=0 plane will copy 1 column on the block
	const bool copy_col = (local_z == 0 && (local_y * BLOCK_SIZE + local_x) < (BLOCK_SIZE + K - 1));
	
	int col_idx = local_y * BLOCK_SIZE + local_x;
	if(copy_bias) {
		local_bias[local_z] = p_bias[out_map];
	}

	for(uint imap = 0; imap < no_inputs; imap++) {
		// pointer to this input map in global memory
		global float *p_imap = p_maps + imap * H * W;
		if(copy_col) {
			#pragma unroll
			for(uint p = 0; p < BLOCK_SIZE + K - 1; p++) {
				map_blk[p][col_idx] = p_imap[row_start + p*W + col_start + col_idx];
			}
		}

		// copy kernel for input map
		if(copy_ker) {
			#pragma unroll
			for(int c = 0; c < K; c++) {
			map_ker[local_z][c][local_x] = 
				p_weights[filter_start + (imap * K + c) * K + local_x];
			}
		}

		barrier(CLK_LOCAL_MEM_FENCE);
		// read 2 rows of the window from the local memory.
		win_data[1][0] = map_blk[local_y * (BLOCK_SIZE/2) + 0][local_x + 0];
		win_data[1][1] = map_blk[local_y * (BLOCK_SIZE/2) + 0][local_x + 1];
		win_data[1][2] = map_blk[local_y * (BLOCK_SIZE/2) + 0][local_x + 2];
		win_data[2][0] = map_blk[local_y * (BLOCK_SIZE/2) + 1][local_x + 0];
		win_data[2][1] = map_blk[local_y * (BLOCK_SIZE/2) + 1][local_x + 1];
		win_data[2][2] = map_blk[local_y * (BLOCK_SIZE/2) + 1][local_x + 2];
		// load kernel into registers
		#pragma unroll
		for(int wr = 0; wr < K; wr++) {
			#pragma unroll
			for(int wc = 0; wc < K; wc++) {
				win_ker[wr][wc] = map_ker[local_z][wr][wc];
			}
		}
		for(int pix = 0; pix < BLOCK_SIZE/2; pix++) {
			// load new row into the last row of the window register.
			#pragma unroll
			for(int r = 0; r < K - 1; r++) {
				#pragma unroll
				for(int c = 0; c < K; c++)
				win_data[r][c] = win_data[r+1][c];
			}
			win_data[K-1][0] = map_blk[local_y * (BLOCK_SIZE/2) + pix + K-1][local_x + 0];
			win_data[K-1][1] = map_blk[local_y * (BLOCK_SIZE/2) + pix + K-1][local_x + 1];
			win_data[K-1][2] = map_blk[local_y * (BLOCK_SIZE/2) + pix + K-1][local_x + 2];
			// compute
			#pragma unroll
			for(int kr = 0; kr < K; kr++) {
				#pragma unroll
				for(int kc = 0; kc < K; kc++) {
					//sum += map_ker[local_z][kr][kc] * map_blk[local_y + kr][local_x + kc];
					sum[pix] += win_ker[kr][kc] * win_data[kr][kc];
				}
			}
		}
		// wait for all work items to finish before overwriting local buffer.
		barrier(CLK_LOCAL_MEM_FENCE);
	}
	// add bias unit and write back
	for(int op = 0; op < BLOCK_SIZE/2; op++) {
		sum[op] += local_bias[local_z];
		p_output[((out_map * gsy + gy)* (BLOCK_SIZE/2) + op) * gsx + gx] = fmax(zero, sum[op]);		
	}
}
#endif
