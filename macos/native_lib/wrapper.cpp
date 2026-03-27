#include "libraw/libraw.h"

#include <cstdint>
#include <cstdlib>
#include <cstring>

#define EXPORT __attribute__((visibility("default"))) __attribute__((used))

struct ThumbnailResult {
  uint8_t* data;
  int size;
  int width;
  int height;
  int format;
};

struct ImageResult {
  uint8_t* data;
  int size;
  int width;
  int height;
};

namespace {

ThumbnailResult empty_thumbnail() { return {nullptr, 0, 0, 0, 0}; }

ImageResult empty_image() { return {nullptr, 0, 0, 0}; }

void copy_rgb_to_bgr(uint8_t* destination,
                     const uint8_t* source,
                     int width,
                     int height) {
  const int total_pixels = width * height;
  for (int i = 0; i < total_pixels; ++i) {
    destination[i * 3 + 0] = source[i * 3 + 2];
    destination[i * 3 + 1] = source[i * 3 + 1];
    destination[i * 3 + 2] = source[i * 3 + 0];
  }
}

ThumbnailResult process_thumbnail(LibRaw& raw_processor) {
  ThumbnailResult result = empty_thumbnail();

  if (raw_processor.unpack_thumb() == LIBRAW_SUCCESS) {
    int error_code = 0;
    libraw_processed_image_t* thumb =
        raw_processor.dcraw_make_mem_thumb(&error_code);

    if (thumb != nullptr) {
      result.size = thumb->data_size;
      result.data = static_cast<uint8_t*>(malloc(static_cast<size_t>(result.size)));
      if (result.data != nullptr) {
        memcpy(result.data, thumb->data, static_cast<size_t>(result.size));
      }

      if (thumb->type == LIBRAW_IMAGE_JPEG) {
        result.format = 0;
      } else if (thumb->type == LIBRAW_IMAGE_BITMAP) {
        result.format = 1;
        result.width = thumb->width;
        result.height = thumb->height;
      }

      LibRaw::dcraw_clear_mem(thumb);
      return result;
    }
  }

  raw_processor.imgdata.params.use_camera_wb = 1;
  raw_processor.imgdata.params.half_size = 1;
  raw_processor.imgdata.params.output_bps = 8;

  if (raw_processor.unpack() == LIBRAW_SUCCESS &&
      raw_processor.dcraw_process() == LIBRAW_SUCCESS) {
    libraw_processed_image_t* image = raw_processor.dcraw_make_mem_image();

    if (image != nullptr) {
      result.format = 1;
      result.width = image->width;
      result.height = image->height;
      result.size = image->data_size;
      result.data = static_cast<uint8_t*>(malloc(static_cast<size_t>(result.size)));

      if (result.data != nullptr) {
        copy_rgb_to_bgr(result.data, image->data, result.width, result.height);
      }

      LibRaw::dcraw_clear_mem(image);
    }
  }

  return result;
}

ImageResult process_preview(LibRaw& raw_processor, int half_size) {
  ImageResult result = empty_image();

  raw_processor.imgdata.params.use_camera_wb = 1;
  raw_processor.imgdata.params.half_size = half_size;
  raw_processor.imgdata.params.output_bps = 8;
  raw_processor.imgdata.params.output_color = 1;

  if (raw_processor.unpack() != LIBRAW_SUCCESS ||
      raw_processor.dcraw_process() != LIBRAW_SUCCESS) {
    return result;
  }

  libraw_processed_image_t* image = raw_processor.dcraw_make_mem_image();
  if (image != nullptr) {
    result.width = image->width;
    result.height = image->height;
    result.size = image->data_size;
    result.data = static_cast<uint8_t*>(malloc(static_cast<size_t>(result.size)));
    if (result.data != nullptr) {
      copy_rgb_to_bgr(result.data, image->data, result.width, result.height);
    }
    LibRaw::dcraw_clear_mem(image);
  }

  return result;
}

}  // namespace

extern "C" {

EXPORT void free_buffer(uint8_t* buffer) {
  if (buffer != nullptr) {
    free(buffer);
  }
}

EXPORT ThumbnailResult get_thumbnail(const char* file_path) {
  if (file_path == nullptr) {
    return empty_thumbnail();
  }

  LibRaw raw_processor;
  if (raw_processor.open_file(file_path) != LIBRAW_SUCCESS) {
    return empty_thumbnail();
  }

  ThumbnailResult result = process_thumbnail(raw_processor);
  raw_processor.recycle();
  return result;
}

EXPORT ThumbnailResult get_thumbnail_from_buffer(uint8_t* buffer, int size) {
  if (buffer == nullptr || size <= 0) {
    return empty_thumbnail();
  }

  LibRaw raw_processor;
  if (raw_processor.open_buffer(buffer, static_cast<size_t>(size)) !=
      LIBRAW_SUCCESS) {
    return empty_thumbnail();
  }

  ThumbnailResult result = process_thumbnail(raw_processor);
  raw_processor.recycle();
  return result;
}

EXPORT ImageResult get_preview(const char* file_path, int half_size) {
  if (file_path == nullptr) {
    return empty_image();
  }

  LibRaw raw_processor;
  if (raw_processor.open_file(file_path) != LIBRAW_SUCCESS) {
    return empty_image();
  }

  ImageResult result = process_preview(raw_processor, half_size);
  raw_processor.recycle();
  return result;
}

EXPORT ImageResult get_preview_from_buffer(uint8_t* buffer,
                                           int size,
                                           int half_size) {
  if (buffer == nullptr || size <= 0) {
    return empty_image();
  }

  LibRaw raw_processor;
  if (raw_processor.open_buffer(buffer, static_cast<size_t>(size)) !=
      LIBRAW_SUCCESS) {
    return empty_image();
  }

  ImageResult result = process_preview(raw_processor, half_size);
  raw_processor.recycle();
  return result;
}

}  // extern "C"
