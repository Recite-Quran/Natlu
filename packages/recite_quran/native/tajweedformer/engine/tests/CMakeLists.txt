# The engine's own tests (ctest). None needs a model file or the network: each runs a piece of the
# inference path on inputs written in the test and compares with values known in advance.
#   zf_sha256    the FIPS 180-4 examples and the padding boundaries
#   zf_vfs       the in-memory file table the web and Apple SDKs load models through
#   zf_libm      the engine's expf, logf and powf: exact values and a fingerprint per function
#   zf_decode    greedy CTC on hand-written log-probs (the function under every greedy transcript)
#   zf_resample  every input rate: output counts, streaming, pass-through, exact scaling, a fingerprint
#   zf_fbank     the model's input features: frame counts, streaming, the floor, a fingerprint
#   zf_kernels   the int8 matmul kernels and both weight layouts against a scalar reference
# `cmake --build <dir> --target zf_tests` builds every test of the repository (for presets that name
# their targets).
if(NOT TARGET zf_tests)
  add_custom_target(zf_tests)
endif()
foreach(t sha256 vfs libm decode resample fbank kernels)
  add_executable(zf_test_${t} test_${t}.c)
  target_compile_options(zf_test_${t} PRIVATE -O2 -Wall -Wextra -Werror)
  target_link_libraries(zf_test_${t} PRIVATE zf_engine)
  add_test(NAME zf_${t} COMMAND zf_test_${t})
  add_dependencies(zf_tests zf_test_${t})
endforeach()
