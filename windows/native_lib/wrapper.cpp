#include "libraw/libraw.h"
#include <cstring>
#include <cstdlib>
#include <vector>

// Cross-platform export macro
#if defined(_WIN32)
#define EXPORT __declspec(dllexport)
#else
#define EXPORT __attribute__((visibility("default"))) __attribute__((used))
#endif

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

    EXPORT ThumbnailResult get_thumbnail(const wchar_t* file_path) {
        ThumbnailResult result = {nullptr, 0, 0, 0, 0};
        LibRaw RawProcessor;
        
        if (RawProcessor.open_file(file_path) != LIBRAW_SUCCESS) {
            return result;
        }

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
                
                // Map LibRaw types to our format
                // LIBRAW_IMAGE_JPEG = 1
                // LIBRAW_IMAGE_BITMAP = 2
                if (thumb->type == LIBRAW_IMAGE_JPEG) {
                    result.format = 0; // JPEG
                } else if (thumb->type == LIBRAW_IMAGE_BITMAP) {
                    result.format = 1; // RGB Bitmap
                    result.width = thumb->width;
                    result.height = thumb->height;
                }
                
                LibRaw::dcraw_clear_mem(thumb);
                RawProcessor.recycle();
                return result;
            }
        }
        
        // Fallback: If unpack_thumb fails (common with some DNGs), try to generate a preview
        // This is slower but better than no thumbnail
        
        // Set parameters for fast processing
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
                        // Convert RGB to BGR for Windows BMP (if needed, or keep RGB and handle in Dart)
                        // Our Dart code wraps it in BMP header. BMP standard is typically BGR?
                        // Actually, Flutter's Image.memory with BMP header:
                        // Most BMPs are BGR. Let's swap.
                        
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
            }
        }

        RawProcessor.recycle();
        return result;
    }

    // Get preview image (fast decoding)
    EXPORT ImageResult get_preview(const wchar_t* file_path, int half_size) {
        ImageResult result = {nullptr, 0, 0, 0};
        LibRaw RawProcessor;

        // Set parameters for speed, sacrificing some quality
        RawProcessor.imgdata.params.use_camera_wb = 1;
        RawProcessor.imgdata.params.half_size = half_size; // 1: Half size, 0: Full size
        RawProcessor.imgdata.params.output_bps = 8; // 8-bit output
        RawProcessor.imgdata.params.output_color = 1; // sRGB

        if (RawProcessor.open_file(file_path) != LIBRAW_SUCCESS) {
            return result;
        }

        if (RawProcessor.unpack() != LIBRAW_SUCCESS) {
            RawProcessor.recycle();
            return result;
        }
        
        // dcraw_process
        if (RawProcessor.dcraw_process() != LIBRAW_SUCCESS) {
            RawProcessor.recycle();
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
                // LibRaw outputs RGB, but Windows BMP expects BGR
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

        RawProcessor.recycle();
        return result;
    }
}
