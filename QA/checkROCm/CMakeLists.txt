cmake_minimum_required(VERSION 3.23)

project(Training_ROCmCheck)


set (A "amdclang")
set (B "amdclang++")
set (C "amdclang-cl")
set (D "amdclang-cpp")
set (E "amdflang")
set (F "amdlld")
set (G "aompcc")
set (H "clang-ocl")
set (I "clinfo")
set (J "hipcc")
set (K "hipconfig")
set (L "hipfc")
set (M "hipify-clang")
set (N "hipify-perl")
# set (O "mygpu")
# set (P "mymcpu")
set (Q "roc-obj")
set (R "roc-obj-extract")
set (S "roc-obj-ls")
set (T "rocfft_rtc_helper")
set (U "rocgdb")
set (V "rocm-smi")
set (W "rocm_agent_enumerator")
set (X "rocminfo")
set (Y "rocprof")
set (Z "rvs")


enable_testing() # Enable CTest

# allow to report to a cdash dashboard
include(CTest)

#
# Verify that the standard ROCm exe's are available on the PATH
#
foreach(X IN LISTS A B C D E F G H I J K L M N O P Q R S T U V W X Y Z )
        message(STATUS "Check for ${X}")
         find_program( ${X}_TOOL_PATH       ${X}            REQUIRED)
         if(NOT ${X}_TOOL_PATH)
                message( STATUS "${X} is required but was not found!")
         endif()
endforeach()

add_test(
  NAME where-am-i
    COMMAND echo current dir is ${CMAKE_CURRENT_SOURCE_DIR}
)


#############################
# amdclang
#############################
add_test(NAME lang
    COMMAND ${CMAKE_COMMAND}
            -DCMD1=amdclang --version
            -DCMD2=amdclang --version
    -P ${CMAKE_CURRENT_SOURCE_DIR}/my_script.cmake
  )


# test apps that respond to --version
foreach(X IN LISTS A B C D E  G H I J K L M N   W X Z )
        message(STATUS "Check version for ${X}")
        add_test(NAME ${X}_version
                 COMMAND
                    bash -c "${X} --version ; "
        )
endforeach()


# test apps that respond to -h
foreach(X IN LISTS  V )
        message(STATUS "Check version for ${X}")
        add_test(NAME ${X}_version
                 COMMAND
                    bash -c "${X} -h ; "
        )
endforeach()


add_test(NAME test
    COMMAND ${CMAKE_COMMAND}
            -DCMD1=df
            -DCMD2=ls
    -P ${CMAKE_CURRENT_SOURCE_DIR}/my_script.cmake
    )



#
# Pass if the amdclang and clang-15 in ROCm are the same
add_test(
    NAME
       amdclang_is_rocm_clang_15
    COMMAND
        bash -c "amdclang --version >/tmp/amdclang.out1; \
                 /opt/rocm/llvm/bin/clang-15 --version >/tmp/amdclang.out2 ;\
                 cmp -n 100 /tmp/amdclang.out1 /tmp/amdclang.out2 "
)

# Pass if the ROCm clang-15 is also the one in /usr/bin 
add_test(
    NAME
       usr_bin_clang-15_is_rocm
    COMMAND
        bash -c "/opt/rocm/llvm/bin/clang-15 --version >/tmp/clang-15.out1 ;\
                 /usr/bin/clang-15 --version >/tmp/clang-15.out2 ;\
                 cmp -n 100 /tmp/clang-15.out1 /tmp/clang-15.out2 ; "
)

# Pass if the ROCm clang-15 is also
# pointed to by the CC environment variable
add_test(
    NAME
    CC_is_rocm_amdclang_15
    COMMAND
        bash -c "/opt/rocm/llvm/bin/clang-15 --version >/tmp/clang-15.out1 ;\
                 $CC --version >/tmp/clang-15.out3 ;\
                 cmp -n 100 /tmp/clang-15.out1 /tmp/clang-15.out3 "
)


