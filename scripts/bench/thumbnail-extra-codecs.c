#include "thumbnail-extra-codecs.h"
#include <stdlib.h>
#include <string.h>
#include <webp/encode.h>
#include <webp/decode.h>
#include <jxl/encode.h>
#include <jxl/decode.h>
#include <jxl/color_encoding.h>
#include <turbojpeg.h>
#include <avif/avif.h>

void bench_free(void *p) { free(p); }
static int copyout(const void *src, size_t n, uint8_t **out, size_t *size) {
    *out = malloc(n); if (!*out) return 0;
    memcpy(*out,src,n); *size=n; return 1;
}
int bench_encode(int codec, const uint8_t *rgba, int w, int h, double quality, int effort, uint8_t **out, size_t *size) {
    *out=NULL; *size=0;
    if(codec==1) {
        uint8_t *p=NULL; size_t n=WebPEncodeRGBA(rgba,w,h,w*4,(float)(quality*100),&p);
        int ok=n && copyout(p,n,out,size); WebPFree(p); return ok;
    }
    if(codec==2) {
        JxlEncoder *enc=JxlEncoderCreate(NULL); if(!enc) return 0;
        JxlBasicInfo info; JxlEncoderInitBasicInfo(&info);
        info.xsize=w; info.ysize=h; info.bits_per_sample=8; info.num_color_channels=3;
        info.num_extra_channels=1; info.alpha_bits=8;
        JxlColorEncoding color; JxlColorEncodingSetToSRGB(&color,JXL_FALSE);
        JxlEncoderFrameSettings *settings=JxlEncoderFrameSettingsCreate(enc,NULL);
        JxlEncoderFrameSettingsSetOption(settings,JXL_ENC_FRAME_SETTING_EFFORT,effort);
        JxlEncoderSetFrameDistance(settings,JxlEncoderDistanceFromQuality((float)(quality*100)));
        JxlPixelFormat format={4,JXL_TYPE_UINT8,JXL_NATIVE_ENDIAN,0};
        int ok=JxlEncoderSetBasicInfo(enc,&info)==JXL_ENC_SUCCESS &&
               JxlEncoderSetColorEncoding(enc,&color)==JXL_ENC_SUCCESS &&
               JxlEncoderAddImageFrame(settings,&format,rgba,(size_t)w*h*4)==JXL_ENC_SUCCESS;
        if(!ok) { JxlEncoderDestroy(enc); return 0; }
        JxlEncoderCloseInput(enc);
        size_t capacity=65536; uint8_t *buffer=malloc(capacity), *next=buffer; size_t available=capacity;
        JxlEncoderStatus status;
        while((status=JxlEncoderProcessOutput(enc,&next,&available))==JXL_ENC_NEED_MORE_OUTPUT) {
            size_t written=(size_t)(next-buffer); capacity*=2;
            uint8_t *grown=realloc(buffer,capacity); if(!grown) {free(buffer); JxlEncoderDestroy(enc); return 0;}
            buffer=grown; next=buffer+written; available=capacity-written;
        }
        if(status==JXL_ENC_SUCCESS) {*out=buffer; *size=(size_t)(next-buffer);} else free(buffer);
        JxlEncoderDestroy(enc); return status==JXL_ENC_SUCCESS;
    }
    if(codec==3) {
        tjhandle handle=tjInitCompress(); unsigned char *p=NULL; unsigned long n=0;
        int ok=tjCompress2(handle,rgba,w,w*4,h,TJPF_RGBA,&p,&n,effort == 1 ? TJSAMP_444 : TJSAMP_420,(int)(quality*100),0)==0;
        if(ok) ok=copyout(p,n,out,size);
        tjFree(p); tjDestroy(handle); return ok;
    }
    if(codec==4) {
        avifImage *image=avifImageCreate(w,h,8,AVIF_PIXEL_FORMAT_YUV420);
        image->colorPrimaries=AVIF_COLOR_PRIMARIES_BT709;
        image->transferCharacteristics=AVIF_TRANSFER_CHARACTERISTICS_SRGB;
        image->matrixCoefficients=AVIF_MATRIX_COEFFICIENTS_BT601;
        avifRGBImage rgb; avifRGBImageSetDefaults(&rgb,image);
        rgb.format=AVIF_RGB_FORMAT_RGBA; rgb.pixels=(uint8_t *)rgba; rgb.rowBytes=w*4; rgb.maxThreads=1;
        avifEncoder *enc=avifEncoderCreate(); enc->codecChoice=AVIF_CODEC_CHOICE_AOM;
        enc->maxThreads=1; enc->speed=effort; enc->quality=(int)(quality*100);
        avifRWData data=AVIF_DATA_EMPTY;
        int ok=avifImageRGBToYUV(image,&rgb)==AVIF_RESULT_OK && avifEncoderWrite(enc,image,&data)==AVIF_RESULT_OK;
        if(ok) ok=copyout(data.data,data.size,out,size);
        avifRWDataFree(&data); avifEncoderDestroy(enc); avifImageDestroy(image); return ok;
    }
    return 0;
}
int bench_decode(int codec, const uint8_t *data, size_t size, uint8_t **rgba, int *w, int *h) {
    *rgba=NULL;
    if(codec==1) {
        if(!WebPGetInfo(data,size,w,h)) return 0;
        size_t n=(size_t)*w**h*4; *rgba=malloc(n);
        if(WebPDecodeRGBAInto(data,size,*rgba,n,*w*4)) return 1;
        free(*rgba); *rgba=NULL; return 0;
    }
    if(codec==2) {
        JxlDecoder *dec=JxlDecoderCreate(NULL); JxlDecoderSubscribeEvents(dec,JXL_DEC_BASIC_INFO|JXL_DEC_COLOR_ENCODING|JXL_DEC_FULL_IMAGE);
        JxlDecoderSetInput(dec,data,size); JxlDecoderCloseInput(dec);
        JxlPixelFormat format={4,JXL_TYPE_UINT8,JXL_NATIVE_ENDIAN,0}; int ok=0;
        while(1) {
            JxlDecoderStatus s=JxlDecoderProcessInput(dec);
            if(s==JXL_DEC_BASIC_INFO) {JxlBasicInfo info; JxlDecoderGetBasicInfo(dec,&info); *w=info.xsize; *h=info.ysize;}
            else if(s==JXL_DEC_COLOR_ENCODING) {JxlColorEncoding color; JxlColorEncodingSetToSRGB(&color,JXL_FALSE); JxlDecoderSetPreferredColorProfile(dec,&color);}
            else if(s==JXL_DEC_NEED_IMAGE_OUT_BUFFER) {
                size_t n=0; JxlDecoderImageOutBufferSize(dec,&format,&n); *rgba=malloc(n);
                if(!*rgba || JxlDecoderSetImageOutBuffer(dec,&format,*rgba,n)!=JXL_DEC_SUCCESS) break;
            } else if(s==JXL_DEC_FULL_IMAGE) {ok=1;break;}
            else if(s==JXL_DEC_ERROR || s==JXL_DEC_NEED_MORE_INPUT || s==JXL_DEC_SUCCESS) break;
        }
        JxlDecoderDestroy(dec); if(!ok) {free(*rgba); *rgba=NULL;} return ok;
    }
    if(codec==3) {
        tjhandle handle=tjInitDecompress(); int subsamp, color;
        int ok=tjDecompressHeader3(handle,data,(unsigned long)size,w,h,&subsamp,&color)==0;
        if(ok) { *rgba=malloc((size_t)*w**h*4); ok=*rgba && tjDecompress2(handle,data,(unsigned long)size,*rgba,*w,*w*4,*h,TJPF_RGBA,0)==0; }
        tjDestroy(handle); if(!ok){free(*rgba);*rgba=NULL;}return ok;
    }
    if(codec==4) {
        avifDecoder *dec=avifDecoderCreate(); dec->maxThreads=1;
        avifImage *image=avifImageCreateEmpty();
        int ok=avifDecoderReadMemory(dec,image,data,size)==AVIF_RESULT_OK;
        if(ok) {
            *w=image->width; *h=image->height;
            avifRGBImage rgb; avifRGBImageSetDefaults(&rgb,image); rgb.format=AVIF_RGB_FORMAT_RGBA; rgb.depth=8; rgb.maxThreads=1;
            *rgba=malloc((size_t)*w**h*4); rgb.pixels=*rgba; rgb.rowBytes=*w*4;
            ok=*rgba && avifImageYUVToRGB(image,&rgb)==AVIF_RESULT_OK;
        }
        avifImageDestroy(image); avifDecoderDestroy(dec); if(!ok){free(*rgba);*rgba=NULL;}return ok;
    }
    return 0;
}
