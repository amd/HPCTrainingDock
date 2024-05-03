echo  "Checking the extra apps ... "
  cd checkExtraApps
  mkdir -p build
  rm -rf ./build/*
  cd ./build
  cmake ..
  cmake --build .
  ctest
  rc=$?
  cd ..
  echo " "

echo "RC=$rc"

