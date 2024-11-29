@echo off

sokol-shdc -i game/shader.glsl -o game/shader.odin -l hlsl5:wgsl -f sokol_odin --save-intermediate-spirv

odin build game -debug