# iOS Native Binaries

Place `zf_tajweed.xcframework` in this folder:
```
packages/recite_quran/ios/Frameworks/zf_tajweed.xcframework
```

This xcframework is built using the GitHub Actions workflow:
`.github/workflows/build_ios_xcframework.yml`

Once placed here, `quran_tajweedformer.podspec` will automatically bundle it into the iOS build, and you can safely delete the `native/` folder from `packages/recite_quran/`.
