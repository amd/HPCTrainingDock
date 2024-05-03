mkdir -p ./build
rm -rf ./build/*
scp -p *.cmake ./build/.
ls -lsa ./build
cd ./build
cmake ..
cmake --build .
ctest
