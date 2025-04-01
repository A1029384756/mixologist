#!/usr/bin/env bash

if ! command -v glslangValidator 2>&1 > /dev/null
then
    echo "glslangValidator not found"
    exit 1
fi

# Convert GLSL to SPIRV
echo "Converting GLSL shaders to SPIRV..."
pushd mixologist_gui/resources/shaders/raw
mkdir -p ../compiled
glslangValidator -V ui.vert -o ../compiled/ui.vert.spv
glslangValidator -V ui.frag -o ../compiled/ui.frag.spv

echo "Done processing shaders."
popd
