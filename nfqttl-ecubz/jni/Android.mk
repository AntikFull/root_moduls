LOCAL_PATH := $(call my-dir)

include $(CLEAR_VARS)

LOCAL_MODULE    := nfqttl
LOCAL_SRC_FILES := ../src/nfqttl.c \
                   ../src/libnetfilter_queue.c \
                   ../src/nlmsg.c \
                   ../src/checksum.c \
                   ../src/libnetlink.c \
                   ../src/libnfnetlink.c \
                   ../src/iftable.c \
                   ../src/rtnl.c

LOCAL_C_INCLUDES := $(LOCAL_PATH)/../src $(LOCAL_PATH)/../include

LOCAL_LDLIBS := -llog

include $(BUILD_EXECUTABLE)
