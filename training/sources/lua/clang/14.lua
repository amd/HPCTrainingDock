 whatis("Clang (LLVM) Version 14 compiler")
 setenv("CC", "/usr/bin/clang-14")
 setenv("CXX", "/usr/bin/clang++-14")
 setenv("F77", "/usr/bin/flang-14")
 setenv("F90", "/usr/bin/flang-14")
 setenv("FC", "/usr/bin/flang-14")
 append_path("INCLUDE_PATH", "/usr/include")
 prepend_path("LIBRARY_PATH", "/usr/lib/llvm-14/lib")
 prepend_path("LD_LIBRARY_PATH", "/usr/lib/llvm-14/lib")
 family("compiler")