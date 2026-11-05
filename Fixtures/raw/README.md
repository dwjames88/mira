# Sample RAW files

Real camera files for `RawIntegrationTests` (Packages/MiraCore). Each is a CC0 1.0 (public domain
dedication) sample from <https://raw.pixls.us> (listing at
<https://raw.pixls.us/json/getrepository.php?set=all>, licence column: "Creative Commons 0 - Public
Domain", <https://creativecommons.org/publicdomain/zero/1.0/>). They are unmodified downloads; the
SHA-256 matches the one raw.pixls.us lists.

| File | Camera | Source URL | SHA-256 |
| --- | --- | --- | --- |
| `sony-ilce7m3.arw` | Sony ILCE-7M3 (A7 III), 14-bit compressed ARW, 6000x4000, 3:2 | <https://raw.pixls.us/getfile.php/2414/nice/Sony%20-%20ILCE-7M3%20-%2014bit%20compressed%20%283:2%29.ARW> | `250784580ea527442c09004417bb0eead484f2bf3ee8f9121a776ac65bb50d0f` |
| `iphone-xs.dng` | Apple iPhone XS, back wide camera, DNG from ProCamera 12.4, 4032x3024 | <https://raw.pixls.us/getfile.php/3372/nice/Apple%20-%20iPhone%20XS%20-%2016bit%20%284:3%29.dng> | `50bc64ee8cfbbfb6c0531e29ab428ff985506a16fe2d1d2e74656f21b54505f6` |
| `iphone-12-pro.dng` | Apple iPhone 12 Pro, DNG with BaselineExposure -0.30, 4032x3024 | <https://raw.pixls.us/getfile.php/4264/nice/Apple%20-%20iPhone%2012%20Pro%20-%208bit%20%284:3%29.DNG> | `e91e77a4533ed7cce551d83330676ea5c47dd5e55fb38adda7819366afdbdfc2` |

Only `iphone-xs.dng` (10 MB) is committed. The Sony and iPhone 12 Pro files are kept out of the repository to keep its history small; download them from the URLs above (and check the SHA-256) into this folder or into the folder named by `MIRA_RAW_DIR` to run those tests. The tests skip any file that is absent. Set `MIRA_RAW_DIR` to read the files from another folder.
