#include <iostream>
#include <fstream>
#include <stdlib.h>
#include "common.h"
#include <time.h>
#include <sys/time.h>
#define TOTAL_RUN 1
#define MATMUL_BLOCKSIZE 2

void im2colOnHost(Matrix&, Matrix&, int, int, int);
__global__ void im2col(Matrix, Matrix, int, int, int, int, int);
int program(int gridSize, int blockSize,  int height, int width,
	int channels, int batch_size, int ksize, int num_kernels, int pad, int stride);
__global__ void blockMatrixMul(Matrix gpu_colin, Matrix gpu_kernel, Matrix gpu_colout);

int main() {
    //image width, height, channel, batch size
    int height = 4;
	int width = 4;
	int channels = 1;
	int batch_size = 1;//128;
    //kernel size, channel
	int ksize = 3; // 5-11
	int num_kernels = 4;
    //conv padding and stride
    int pad = 1; // 0-2
	int stride = 1; // 1
    struct timeval start;
    struct timeval stop;
    double oneTime=0;
    double totalTime=0;
    int numWindowPerRow = (width - ksize) / stride + 1;
    int numWindowPerCol = (height - ksize) / stride + 1;
    int numWindowPerChannel = numWindowPerRow * numWindowPerCol; //number of lside window in each image channel
    int kernelNum = numWindowPerChannel * channels;
    //Mesure effect of different block size
    // printf("blockSize, gridSize, avgTime\n");
    std::fstream fperflog("perflog.csv", std::ios::out);
    fperflog << "numThread, blockSize, gridSize, avgTime" << std::endl;
    for (int blockSize=1; blockSize <= 2048; blockSize*=2) {
        //total number of thread < 2 * (number elements in outCol)
        unsigned int MAX_GRID_SIZE = (kernelNum + blockSize - 1) / blockSize; 
        for (int gridSize=1; gridSize <= 2048; gridSize*=2) {
            if (gridSize >= MAX_GRID_SIZE) {
                continue;
            }
            totalTime = 0;
            for (int i=0; i < TOTAL_RUN; i++) {
                gettimeofday(&start, NULL);
                program(gridSize, blockSize, height, width, channels, batch_size, ksize, 
                num_kernels, pad, stride);
                gettimeofday(&stop, NULL);
                oneTime = (stop.tv_sec - start.tv_sec) * 1000.0;
                oneTime += (stop.tv_usec - start.tv_usec) / 1000.0;
                totalTime += oneTime;
            }
            fperflog <<blockSize * gridSize << "," <<  blockSize << ","             
                                      << gridSize << "," << totalTime / TOTAL_RUN << std::endl;
            break; //debug
        }
        break; //debug
    }
    fperflog.close();
    return 0;
}

//Host code
int program(int gridSize, int blockSize,  int height, int width,
	int channels, int batch_size, int ksize, int num_kernels, int pad, int stride)
{
    Matrix image;
    Matrix kernel;
    Matrix gpu_image;
    Matrix gpu_kernel;
    generate_data(image, kernel, height, width, channels, 
                        batch_size, ksize, num_kernels, stride, pad);

    transferToDevice(image, gpu_image);
    transferToDevice(kernel, gpu_kernel);

    Matrix gpu_colin;
    gpu_colin.width = ksize * ksize; //width of each row = kernel size
    int numWindowPerRow = (gpu_image.width - ksize) / stride + 1;
    int numWindowPerCol = (gpu_image.height - ksize) / stride + 1;
    int numWindowPerChannel = numWindowPerRow * numWindowPerCol; //number of lside window in each image channel
    int kernelNum = numWindowPerChannel * channels;
    gpu_colin.height = kernelNum; //KERNEL_NUM
    gpu_colin.channels = 1;
    gpu_colin.batch_size = 1;
    cudaMalloc((void**) &gpu_colin.elements, sizeof(float)*gpu_colin.height * gpu_colin.width * gpu_colin.channels);  
    im2col<<<gridSize, blockSize>>>(gpu_image, gpu_colin, ksize, 
                            stride, numWindowPerRow, numWindowPerCol, numWindowPerChannel);

    
    // /**
    //For debug: compare serial result on host and multi-thread result on gpu
    Matrix colOutDev;    
    Matrix outHost;
    colOutDev.width = gpu_colin.width; //each row is of kernel size
    colOutDev.height = gpu_colin.height ;//KERNEL_NUM
    colOutDev.channels = gpu_colin.channels;
    colOutDev.batch_size = gpu_colin.batch_size;
    transferFromDevice(gpu_colin, colOutDev);
    printMatrix(colOutDev, "colOutDev");    
    im2colOnHost(image, outHost, pad, stride, ksize);    
    printMatrix(image, "image");
    printMatrix(outHost, "colOutHost");
    for (int i=0; i<colOutDev.width * colOutDev.height; i++) {
        if (colOutDev.elements[i] != outHost.elements[i]) {
            std::cout<< "wrong in index: " << i << '\n';
        }
    }
    free(outHost.elements);
    free(colOutDev.elements);
    // */
    Matrix gpu_colout;
    gpu_colout.width = gpu_colin.height;
    gpu_colout.height = num_kernels;
    gpu_colout.channels = 1;
    gpu_colout.batch_size = 1;
    cudaMalloc((void**) &gpu_colout.elements, gpu_colout.width *
            gpu_colout.height * gpu_colout.channels * gpu_colout.batch_size * sizeof(float));
    dim3 dimBlock(MATMUL_BLOCKSIZE, MATMUL_BLOCKSIZE);
    // int xx = gpu_colin.height / MATMUL_BLOCKSIZE;
    // int cc = num_kernels / MATMUL_BLOCKSIZE;
    // std::cout << cc << " " << xx << std::endl;
    dim3 dimGrid(gpu_colin.height / MATMUL_BLOCKSIZE, num_kernels / MATMUL_BLOCKSIZE);
    blockMatrixMul<<<dimGrid, dimBlock>>>(gpu_colin, gpu_kernel, gpu_colout);

    Matrix a;
    a.width = gpu_colout.width;
    a.height = gpu_colout.height;
    a.channels = gpu_colout.channels;
    a.batch_size = gpu_colout.batch_size;
    a.elements = (float *) malloc(a.width*a.height*sizeof(float));
    cudaMemcpy(a.elements, gpu_colout.elements, sizeof(float)*a.width*a.height,cudaMemcpyDeviceToHost);
    printMatrix(a, "gpu_colout");


    cudaFree(gpu_image.elements);
    cudaFree(gpu_kernel.elements);
    cudaFree(gpu_colin.elements);
    cudaFree(gpu_colout.elements);
    free(image.elements);
    free(kernel.elements);
    
    return 0;
}



void im2colOnHost(Matrix &image, Matrix &colOutHost, int pad, int stride, int ksize) {
    // std::cout<<"image: "<<image.width<<" " << image.height << " " << image.channels << "\n";
    int outWidth = (image.width - ksize) / stride + 1; //(image.width + 2*pad - ksize) / stride + 1;
    int outHeight = (image.height - ksize) / stride + 1; //(image.height + 2*pad - ksize) / stride + 1;
    int colOutHeight = outWidth * outHeight * image.channels;
    // std::cout<<"out: "<<outWidth<<" " << outHeight << "\n";
    colOutHost.height = colOutHeight;
    colOutHost.width = ksize * ksize;
    colOutHost.channels = 1;
    colOutHost.batch_size = 1;
    colOutHost.elements = (float*) malloc(colOutHeight*ksize*ksize*sizeof(float));
    int colOutIdy = 0;
    for (int channelId=0; channelId < image.channels; channelId++) {
        for (int rowIdx=0; rowIdx < image.height-ksize+1; rowIdx++) {  
            for (int colIdx=0; colIdx < image.width-ksize+1; colIdx++) {  
                for (int kernelY=0; kernelY < ksize; kernelY++) {        
                    for (int kernelX=0; kernelX < ksize; kernelX++) {                                            
                        int colOutIdx = kernelY * ksize + kernelX;
                        int inIdx = colIdx + kernelX;
                        int inIdy = channelId * image.height + rowIdx + kernelY;
                        // std::cout<<image.elements[inIdy * image.width + inIdx]<<" ";
                        colOutHost.elements[colOutIdy * ksize*ksize + colOutIdx] = image.elements[inIdy * image.width + inIdx];
                    }
                }
                colOutIdy += 1; //append to the last of colOutHost
            }
        }
    }
    // std::cout << "\n";
}


//kernel functions
__global__ void im2col(Matrix gpu_image, Matrix gpu_colin, int ksize, int stride, 
                            int numWindowPerRow, int numWindowPerCol, int numWindowPerChannel) {
    // printf("hello from device");
    for (int idx = blockIdx.x * blockDim.x + threadIdx.x;
    idx < gpu_colin.height * gpu_colin.width; idx += blockDim.x * gridDim.x) {
        int colOutIdy = idx / gpu_colin.width; //index of slide window
        int colOutIdx = idx % gpu_colin.width;
        int windowIdy = colOutIdy / numWindowPerRow;
        int windowIdx = colOutIdy % numWindowPerRow;
        int channelIdy = colOutIdy / numWindowPerChannel;
        int eleInWindowIdy = colOutIdx / ksize;
        int eleInWindonIdx = colOutIdx % ksize;
        int inIdy = channelIdy * (ksize-1) + windowIdy + eleInWindowIdy; //Todo: -1 wrong in diff stride
        int inIdx = windowIdx + eleInWindonIdx;
        gpu_colin.elements[colOutIdy * gpu_colin.width + colOutIdx] = 
                            gpu_image.elements[inIdy*gpu_image.width + inIdx];
        // printf("%f ", gpu_colin.elements[colOutIdy * gpu_colin.width + colOutIdx]);
    }
}


__global__ void blockMatrixMul(Matrix gpu_colin, Matrix gpu_kernel, Matrix gpu_colout) {
    // coordinates of block
    int blockRow_k = blockIdx.y; //row index of kernel marix
    int blockRow_c = blockIdx.x; //row index of gpu_colin matrix 
    printf("blockRow_k, blockRow_c: %d %d\n", blockRow_k, blockRow_c);
    //coordinates of element in block
    int row = threadIdx.y;
    int col = threadIdx.x; //(gpu_colin.width / MATMUL_BLOCKSIZE)
    for (int m=0; m < 1; m++) {
        __shared__ float As[MATMUL_BLOCKSIZE][MATMUL_BLOCKSIZE];
        __shared__ float Bs[MATMUL_BLOCKSIZE][MATMUL_BLOCKSIZE];
        int Aindy = blockRow_k * blockDim.y + row;
        int Aindx = m * blockDim.x + col;
        As[row][col] = gpu_colin.elements[Aindy * gpu_colin.width + Aindx];
        int Bindy = blockRow_c * blockDim.y + row;
        int Bindx = m * blockDim.x + col;
        Bs[row][col] = gpu_kernel.elements[Bindy * gpu_colin.width + Bindx];
        __syncthreads();
        printf("Bs, %d %d,  %f \n", row, col, Bs[row][col]);
        for (int e=0; e < blockDim.x; e++) {
            gpu_colout.elements[
                (blockRow_k + row) * gpu_colout.width 
                + blockRow_c + row ] += As[row][e] * Bs[col][e];
            printf("%d %d, As %f, Bs %f \n", blockRow_k + row, blockRow_c + row, As[row][e], Bs[row][e]);
        }        
    }

}