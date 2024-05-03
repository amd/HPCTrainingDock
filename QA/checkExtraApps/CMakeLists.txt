cmake_minimum_required(VERSION 3.16)

project(Training_extraAppCheck)

# Verify that the expected extra applications and libraries are installed

# Find tools and data
# autotools - check directly in test
# boost - check directly in test
# eigen - check directly in test
# fftw - check directly in test
# gmp  - check directly in test
# gsl  - check directly in test
# hdf5-openmpi  - check directly in test
# h5sparse - check directly in test
# lapacke - check directly in test
# magma - check directly in test
# matplotlib - check directly in test
# miniconda - unknown how to check
# mpfr - check directly in test
# mpi4py  - check directly in test
# numpy - check directly in test
# openblas  - check directly in test 
# openssl  - check directly in test 
# parmetis - check directly in test 
# scipy - check directly in test 
# swig - check directly in test 

find_program(EMACS_TOOL_PATH emacs)
find_program(MINICONDS_TOOL_PATH miniconda)
find_program(SWIG_TOOL_PATH swig)
find_program(TMUX_TOOL_PATH tmux)
find_program(VIM_TOOL_PATH vim)

find_program(MPIRUN_TOOL_PATH mpirun)

if(NOT EMACS_TOOL_PATH)   
	message( STATUS "emacs is required but was not found!") 
endif()
if(NOT VIM_TOOL_PATH)     
	message( STATUS "vi/vim is required but was not found!") 
endif()
if(NOT MINICONDA_TOOL_PATH)  
	message( STATUS "miniconda is required but was not found!") 
endif()

if(NOT MPIRUN_TOOL_PATH)
    message(
        STATUS
            "mpirun is required for mpirun wrapper but was not found!"
    )
endif()

enable_testing() # Enable CTest

# allow to report to a cdash dashboard
include(CTest)

add_test(
  NAME where-am-i
  COMMAND echo current dir is ${CMAKE_CURRENT_SOURCE_DIR}
)

#############################
# autotools 
#############################
add_test(
  NAME autotools 
  COMMAND ${BASH_EXECUTABLE} apt list autotools-dev
  )

set_tests_properties(autotools PROPERTIES
	PASS_REGULAR_EXPRESSION ".*autotools.*")

set_tests_properties(autotools PROPERTIES
	FAIL_REGULAR_EXPRESSION ".*not found.*")

#############################
# boost 
#############################
add_test(
  NAME boost  
  COMMAND ${BASH_EXECUTABLE} apt list --installed libboost*
  )

set_tests_properties(boost PROPERTIES
	PASS_REGULAR_EXPRESSION ".*boost.*")

set_tests_properties(boost PROPERTIES
	FAIL_REGULAR_EXPRESSION ".*not found.*")

#############################
# eigen 
#############################
add_test(
  NAME eigen  
  COMMAND ${BASH_EXECUTABLE} apt list --installed libeigen3*
  )

set_tests_properties(eigen PROPERTIES
	PASS_REGULAR_EXPRESSION ".*libeigen3-dev.*")

set_tests_properties(eigen PROPERTIES
	FAIL_REGULAR_EXPRESSION ".*not found.*")

#############################
# emacs 
#############################
add_test(
  NAME emacs 
  COMMAND ${BASH_EXECUTABLE} emacs --version 
  )

set_tests_properties(emacs PROPERTIES
	PASS_REGULAR_EXPRESSION ".*Emacs.*")

set_tests_properties(emacs PROPERTIES
	FAIL_REGULAR_EXPRESSION ".*not found.*")

#############################
# fftw  
#############################
add_test(
  NAME fftw  
  COMMAND ${BASH_EXECUTABLE} apt list --installed libfftw3*
  )

set_tests_properties(fftw PROPERTIES
	PASS_REGULAR_EXPRESSION ".*libfftw3-dev.*")

set_tests_properties(fftw PROPERTIES
	FAIL_REGULAR_EXPRESSION ".*not found.*")

#############################
# gmp  
#############################
add_test(
  NAME gmp  
  COMMAND ${BASH_EXECUTABLE} apt list --installed libgmp* 
  )

set_tests_properties(gmp PROPERTIES
	PASS_REGULAR_EXPRESSION ".*libgmp-dev.*")

set_tests_properties(gmp PROPERTIES
	PASS_REGULAR_EXPRESSION ".*libgmp10.*")

set_tests_properties(gmp PROPERTIES
	FAIL_REGULAR_EXPRESSION ".*not found.*")

#############################
# gsl  
#############################
add_test(
  NAME gsl  
  COMMAND ${BASH_EXECUTABLE} apt list --installed libgsl* 
  )

set_tests_properties(gsl PROPERTIES
	PASS_REGULAR_EXPRESSION ".*libgsl-dev.*")

set_tests_properties(gsl PROPERTIES
	PASS_REGULAR_EXPRESSION ".*libgsl27.*")

set_tests_properties(gsl PROPERTIES
	PASS_REGULAR_EXPRESSION ".*libgslcblas0.*")

set_tests_properties(gsl PROPERTIES
	FAIL_REGULAR_EXPRESSION ".*not found.*")

#############################
# hdf5-openmpi  
#############################
add_test(
  NAME hdf5-openmpi 
  COMMAND ${BASH_EXECUTABLE} apt list --installed libhdf5-openmpi*
  )

set_tests_properties(hdf5-openmpi PROPERTIES
	PASS_REGULAR_EXPRESSION ".*libhdf5-openmpi.*")

set_tests_properties(hdf5-openmpi PROPERTIES
	FAIL_REGULAR_EXPRESSION ".*not found.*")


#############################
# h5sparse
#############################
add_test(
  NAME h5sparse 
  COMMAND ${BASH_EXECUTABLE} apt list --installed *h5sparse* 
  )

set_tests_properties(h5sparse PROPERTIES
	PASS_REGULAR_EXPRESSION ".python3-h5sparse.*")

set_tests_properties(h5sparse PROPERTIES
	FAIL_REGULAR_EXPRESSION ".*not found.*")

#############################
# lapack 
#############################
add_test(
  NAME lapack 
  COMMAND ${BASH_EXECUTABLE} apt list --installed liblapack*
  )

set_tests_properties(lapack PROPERTIES
	PASS_REGULAR_EXPRESSION ".*liblapack-dev.*")

set_tests_properties(lapack PROPERTIES
	PASS_REGULAR_EXPRESSION ".*liblapack3.*")

set_tests_properties(lapack PROPERTIES
	PASS_REGULAR_EXPRESSION ".*liblapacke-dev.*")

set_tests_properties(lapack PROPERTIES
	PASS_REGULAR_EXPRESSION ".*liblapacke.*")

set_tests_properties(lapack PROPERTIES
	FAIL_REGULAR_EXPRESSION ".*not found.*")


#############################
#magma 
#############################
add_test(
  NAME magma  
  COMMAND ${BASH_EXECUTABLE} apt list --installed libmagma* 
  )

set_tests_properties(magma PROPERTIES
	PASS_REGULAR_EXPRESSION ".*libmagma-dev.*")

set_tests_properties(magma PROPERTIES
	PASS_REGULAR_EXPRESSION ".*libmagma2.*")

set_tests_properties(magma PROPERTIES
	FAIL_REGULAR_EXPRESSION ".*not found.*")

#############################
# matplotlib
#############################
add_test(
  NAME  matplotlib  
  COMMAND ${BASH_EXECUTABLE} apt list --installed *matplotlib*
  )

set_tests_properties(matplotlib PROPERTIES
	PASS_REGULAR_EXPRESSION ".*python3-matplotlib.*")

set_tests_properties(matplotlib PROPERTIES
	FAIL_REGULAR_EXPRESSION ".*not found.*")

#############################
# miniconda 
#############################
add_test(
  NAME miniconda 
  COMMAND ${BASH_EXECUTABLE} miniconda  --version 
  )

set_tests_properties(miniconda PROPERTIES
	PASS_REGULAR_EXPRESSION ".*miniconda.*")

set_tests_properties(miniconda PROPERTIES
	FAIL_REGULAR_EXPRESSION ".*not found.*")

#############################
# mpfr 
#############################
add_test(
  NAME mpfr 
  COMMAND ${BASH_EXECUTABLE} apt list --installed libmpfr* 
  )

set_tests_properties(mpfr PROPERTIES
	PASS_REGULAR_EXPRESSION ".*libmpfr-dev.*")

set_tests_properties(mpfr PROPERTIES
	PASS_REGULAR_EXPRESSION ".*libmpfr6.*")

set_tests_properties(mpfr PROPERTIES
	PASS_REGULAR_EXPRESSION ".*libmpfrc.*")

set_tests_properties(mpfr PROPERTIES
	FAIL_REGULAR_EXPRESSION ".*not found.*")

#############################
# mpi4py 
#############################
add_test(
  NAME  mpi4py  
  COMMAND ${BASH_EXECUTABLE} apt list --installed *mpi4py* 
  )

set_tests_properties(mpi4py PROPERTIES
	PASS_REGULAR_EXPRESSION ".*python3-mpi4py.*")

set_tests_properties(mpi4py PROPERTIES
	FAIL_REGULAR_EXPRESSION ".*not found.*")

#############################
#i numpy  
#############################
add_test(
  NAME numpy  
  COMMAND ${BASH_EXECUTABLE} apt list --installed libboost-numpy*
  )

set_tests_properties(numpy PROPERTIES
	PASS_REGULAR_EXPRESSION ".*libboost-numpy.*")

set_tests_properties(numpy PROPERTIES
	FAIL_REGULAR_EXPRESSION ".*not found.*")

#############################
# openblas 
#############################
add_test(
  NAME  openblas  
  COMMAND ${BASH_EXECUTABLE} apt list --installed libopenblas*
  )

set_tests_properties(openblas PROPERTIES
	PASS_REGULAR_EXPRESSION ".*libopenblas0.*")

set_tests_properties(openblas PROPERTIES
	PASS_REGULAR_EXPRESSION ".*libopenblas-dev.*")

set_tests_properties(openblas PROPERTIES
	PASS_REGULAR_EXPRESSION ".*libopenblas64-0.*")

set_tests_properties(openblas PROPERTIES
	PASS_REGULAR_EXPRESSION ".*libopenblas64-dev.*")

set_tests_properties(openblas PROPERTIES
	FAIL_REGULAR_EXPRESSION ".*not found.*")

#############################
# openssl
#############################
add_test(
  NAME  openssl
  COMMAND ${BASH_EXECUTABLE} apt list --installed openssl*
  )

set_tests_properties(openssl PROPERTIES
	PASS_REGULAR_EXPRESSION ".*openssl.*")

set_tests_properties(openssl PROPERTIES
	FAIL_REGULAR_EXPRESSION ".*not found.*")

#############################
# parmetis 
#############################
add_test(
  NAME  parmetis 
  COMMAND ${BASH_EXECUTABLE} apt list --installed libparmetis*
  )

set_tests_properties(parmetis PROPERTIES
	PASS_REGULAR_EXPRESSION ".*libparmetis4.0.*")

set_tests_properties(parmetis PROPERTIES
	FAIL_REGULAR_EXPRESSION ".*not found.*")

#############################
# scipy 
#############################
add_test(
  NAME scipy 
  COMMAND ${BASH_EXECUTABLE} apt list --installed *scipy* 
  )

set_tests_properties(scipy PROPERTIES
	PASS_REGULAR_EXPRESSION ".python3-scipy*.*")

set_tests_properties(scipy PROPERTIES
	FAIL_REGULAR_EXPRESSION ".*not found.*")

#############################
# swig 
#############################
add_test(
  NAME swig  
  COMMAND ${BASH_EXECUTABLE} apt list --installed *swig* 
  )

set_tests_properties(swig PROPERTIES
	PASS_REGULAR_EXPRESSION ".*swig.*")

set_tests_properties(swig PROPERTIES
	FAIL_REGULAR_EXPRESSION ".*not found.*")

#############################
# tmux 
#############################
add_test(
  NAME tmux 
  COMMAND ${BASH_EXECUTABLE} tmux --version 
  )

set_tests_properties(tmux PROPERTIES
	PASS_REGULAR_EXPRESSION ".*tmux.*")

set_tests_properties(tmux PROPERTIES
	FAIL_REGULAR_EXPRESSION ".*not found.*")

#############################
# vim 
#############################
add_test(
  NAME vim 
  COMMAND ${BASH_EXECUTABLE} vim --version 
  )

set_tests_properties(vim PROPERTIES
	PASS_REGULAR_EXPRESSION ".*VIM.*")

set_tests_properties(vim PROPERTIES
	FAIL_REGULAR_EXPRESSION ".*not found.*")


