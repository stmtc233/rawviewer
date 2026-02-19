#include "libraw/libraw.h"
#include <cstring>
#include <cstdlib>
#include <vector>
#include <android/log.h>

#define LOG_TAG "NativeLib"
#define LOGD(...) __android_log_print(ANDROID_LOG_DEBUG, LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

#define EXPORT __attribute__((visibility("default"))) __attribute__((used))

extern "C" {

    struct ThumbnailResult {
        uint8_t* data;
        int size;
        int width;
        int height;
        int format; // 0: JPEG, 1: RGB Bitmap
    };

    struct ImageResult {
        uint8_t* data; // RGB data
        int size;
        int width;
        int height;
    };

    // Helper function to free memory
    EXPORT void free_buffer(uint8_t* buffer) {
        if (buffer) {
            free(buffer);
        }
    }

    ThumbnailResult process_thumbnail(LibRaw& RawProcessor) {
        ThumbnailResult result = {nullptr, 0, 0, 0, 0};

        // Try to unpack thumbnail
        if (RawProcessor.unpack_thumb() == LIBRAW_SUCCESS) {
            int errc = 0;
            libraw_processed_image_t *thumb = RawProcessor.dcraw_make_mem_thumb(&errc);
            
            if (thumb) {
                // Copy data
                result.size = thumb->data_size;
                result.data = (uint8_t*)malloc(result.size);
                if (result.data) {
                    memcpy(result.data, thumb->data, result.size);
                }
                
                if (thumb->type == LIBRAW_IMAGE_JPEG) {
                    result.format = 0; // JPEG
                } else if (thumb->type == LIBRAW_IMAGE_BITMAP) {
                    result.format = 1; // RGB Bitmap
                    result.width = thumb->width;
                    result.height = thumb->height;
                }
                
                LibRaw::dcraw_clear_mem(thumb);
                return result;
            }
        } else {
            LOGD("unpack_thumb failed");
        }
        
        // Fallback: Generate preview from raw data
        RawProcessor.imgdata.params.use_camera_wb = 1;
        RawProcessor.imgdata.params.half_size = 1; // Half size for speed
        RawProcessor.imgdata.params.output_bps = 8;
        
        if (RawProcessor.unpack() == LIBRAW_SUCCESS) {
            if (RawProcessor.dcraw_process() == LIBRAW_SUCCESS) {
                libraw_processed_image_t *image = RawProcessor.dcraw_make_mem_image();
                
                if (image) {
                    result.format = 1; // RGB Bitmap
                    result.width = image->width;
                    result.height = image->height;
                    result.size = image->data_size;
                    result.data = (uint8_t*)malloc(result.size);
                    
                    if (result.data) {
                        // Convert RGB to BGR for BMP header
                        uint8_t* src = image->data;
                        uint8_t* dst = result.data;
                        int total_pixels = result.width * result.height;
                        
                        for (int i = 0; i < total_pixels; ++i) {
                            dst[i * 3 + 0] = src[i * 3 + 2]; // B
                            dst[i * 3 + 1] = src[i * 3 + 1]; // G
                            dst[i * 3 + 2] = src[i * 3 + 0]; // R
                        }
                    }
                    LibRaw::dcraw_clear_mem(image);
                }
            } else {
                LOGD("dcraw_process failed");
            }
        } else {
             LOGD("unpack failed");
        }

        return result;
    }

    EXPORT ThumbnailResult get_thumbnail(const char* file_path) {
        LibRaw RawProcessor;
        int ret = RawProcessor.open_file(file_path);
        if (ret != LIBRAW_SUCCESS) {
            LOGE("open_file failed: %d for %s", ret, file_path);
            return {nullptr, 0, 0, 0, 0};
        }
        
        ThumbnailResult result = process_thumbnail(RawProcessor);
        RawProcessor.recycle();
        return result;
    }

    EXPORT ThumbnailResult get_thumbnail_from_buffer(uint8_t* buffer, size_t size) {
        LibRaw RawProcessor;
        int ret = RawProcessor.open_buffer(buffer, size);
        if (ret != LIBRAW_SUCCESS) {
             LOGE("open_buffer failed: %d", ret);
             return {nullptr, 0, 0, 0, 0};
        }

        ThumbnailResult result = process_thumbnail(RawProcessor);
        RawProcessor.recycle();
        return result;
    }

    ImageResult process_preview(LibRaw& RawProcessor, int half_size) {
        ImageResult result = {nullptr, 0, 0, 0};

        // Set parameters for speed, sacrificing some quality
        RawProcessor.imgdata.params.use_camera_wb = 1;
        RawProcessor.imgdata.params.half_size = half_size; // 1: Half size, 0: Full size
        RawProcessor.imgdata.params.output_bps = 8; // 8-bit output
        RawProcessor.imgdata.params.output_color = 1; // sRGB

        if (RawProcessor.unpack() != LIBRAW_SUCCESS) {
            return result;
        }
        
        // dcraw_process
        if (RawProcessor.dcraw_process() != LIBRAW_SUCCESS) {
            return result;
        }

        // Convert to memory image
        libraw_processed_image_t *image = RawProcessor.dcraw_make_mem_image();
        
        if (image) {
            result.width = image->width;
            result.height = image->height;
            result.size = image->data_size;
            result.data = (uint8_t*)malloc(result.size);
            if (result.data) {
                // Copy data and swap R/B channels for BMP (BGR)
                uint8_t* src = image->data;
                uint8_t* dst = result.data;
                int total_pixels = result.width * result.height;
                
                for (int i = 0; i < total_pixels; ++i) {
                    dst[i * 3 + 0] = src[i * 3 + 2]; // B
                    dst[i * 3 + 1] = src[i * 3 + 1]; // G
                    dst[i * 3 + 2] = src[i * 3 + 0]; // R
                }
            }
            LibRaw::dcraw_clear_mem(image);
        }
        
        return result;
    }

    // Get preview image (fast decoding)
    EXPORT ImageResult get_preview(const char* file_path, int half_size) {
        LibRaw RawProcessor;
        int ret = RawProcessor.open_file(file_path);
        if (ret != LIBRAW_SUCCESS) {
            LOGE("get_preview open_file failed: %d", ret);
            return {nullptr, 0, 0, 0};
        }

        ImageResult result = process_preview(RawProcessor, half_size);
        RawProcessor.recycle();
        return result;
    }

    EXPORT ImageResult get_preview_from_buffer(uint8_t* buffer, size_t size, int half_size) {
        LibRaw RawProcessor;
        int ret = RawProcessor.open_buffer(buffer, size);
        if (ret != LIBRAW_SUCCESS) {
            LOGE("get_preview open_buffer failed: %d", ret);
            return {nullptr, 0, 0, 0};
        }

        ImageResult result = process_preview(RawProcessor, half_size);
        RawProcessor.recycle();
        return result;
    }
}
