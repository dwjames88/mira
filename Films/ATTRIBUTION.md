# Film look attribution

**Collection:** RawTherapee Film Simulation Collection (Hald CLUT), version 2015-09-20
**Author:** Pat David. The archive README also credits Pavlov Dmitry and Michael Ezra.
**Source:** https://rawtherapee.com/shared/HaldCLUT.zip (archive last-modified 20 Sep 2015)
Related pages named in the README: http://rawpedia.rawtherapee.com/Film_Simulation, http://blog.patdavid.net/2013/08/film-emulation-presets-in-gmic-gimp.html, http://blog.patdavid.net/2013/09/film-emulation-presets-in-gmic-gimp.html

**Licence:** Creative Commons Attribution-ShareAlike. The archive README states "CC BY-SA 4.0" (https://creativecommons.org/licenses/by-sa/4.0/). The collection is also commonly cited as CC BY-SA 3.0 (https://creativecommons.org/licenses/by-sa/3.0/); the version the archive itself declares is 4.0, which is what applies here. See LICENSE-LUTS.

The original PNG files are kept **unmodified**, byte for byte, only renamed, in `FilmSources/HaldCLUT/` of the source repository. The app does not bundle the PNGs: it ships each look resampled from 64³ to 48³ (16-bit, trilinear) and compressed into `Packed/<id>.mlut`, regenerated deterministically from the PNGs with `mira-sheet --pack-films FilmSources Films`. The packed files are an adaptation of the collection and are distributed under the same CC BY-SA 4.0 licence; derivative works of the LUTs must be shared under the same licence.

Film stock names are used for information only; no affiliation with or endorsement by the trademark owners (from the archive README disclaimer).

| id | original file in archive |
|----|--------------------------|
| agfa-ultra-color-100 | HaldCLUT/Color/Agfa/Agfa Ultra Color 100.png |
| agfa-vista-200 | HaldCLUT/Color/Agfa/Agfa Vista 200.png |
| fuji-pro-160c | HaldCLUT/Color/Fuji/Fuji 160C 2.png |
| fuji-pro-160c-minus-1 | HaldCLUT/Color/Fuji/Fuji 160C 1 -.png |
| fuji-pro-160c-plus-1 | HaldCLUT/Color/Fuji/Fuji 160C 3 +.png |
| fuji-pro-160c-plus-2 | HaldCLUT/Color/Fuji/Fuji 160C 4 ++.png |
| fuji-pro-400h | HaldCLUT/Color/Fuji/Fuji 400H 2.png |
| fuji-pro-400h-minus-1 | HaldCLUT/Color/Fuji/Fuji 400H 1 -.png |
| fuji-pro-400h-plus-1 | HaldCLUT/Color/Fuji/Fuji 400H 3 +.png |
| fuji-pro-400h-plus-2 | HaldCLUT/Color/Fuji/Fuji 400H 4 ++.png |
| fuji-pro-800z | HaldCLUT/Color/Fuji/Fuji 800Z 2.png |
| fuji-pro-800z-minus-1 | HaldCLUT/Color/Fuji/Fuji 800Z 1 -.png |
| fuji-pro-800z-plus-1 | HaldCLUT/Color/Fuji/Fuji 800Z 3 +.png |
| fuji-pro-800z-plus-2 | HaldCLUT/Color/Fuji/Fuji 800Z 4 ++.png |
| fuji-superia-100 | HaldCLUT/Color/Fuji/Fuji Superia 100 2.png |
| fuji-superia-100-minus-1 | HaldCLUT/Color/Fuji/Fuji Superia 100 1 -.png |
| fuji-superia-100-plus-1 | HaldCLUT/Color/Fuji/Fuji Superia 100 3 +.png |
| fuji-superia-100-plus-2 | HaldCLUT/Color/Fuji/Fuji Superia 100 4 ++.png |
| fuji-superia-1600 | HaldCLUT/Color/Fuji/Fuji Superia 1600 2.png |
| fuji-superia-1600-minus-1 | HaldCLUT/Color/Fuji/Fuji Superia 1600 1 -.png |
| fuji-superia-1600-plus-1 | HaldCLUT/Color/Fuji/Fuji Superia 1600 3 +.png |
| fuji-superia-1600-plus-2 | HaldCLUT/Color/Fuji/Fuji Superia 1600 4 ++.png |
| fuji-superia-200 | HaldCLUT/Color/Fuji/Fuji Superia 200.png |
| fuji-superia-400 | HaldCLUT/Color/Fuji/Fuji Superia 400 2.png |
| fuji-superia-400-minus-1 | HaldCLUT/Color/Fuji/Fuji Superia 400 1 -.png |
| fuji-superia-400-plus-1 | HaldCLUT/Color/Fuji/Fuji Superia 400 3 +.png |
| fuji-superia-400-plus-2 | HaldCLUT/Color/Fuji/Fuji Superia 400 4 ++.png |
| fuji-superia-800 | HaldCLUT/Color/Fuji/Fuji Superia 800 2.png |
| fuji-superia-800-minus-1 | HaldCLUT/Color/Fuji/Fuji Superia 800 1 -.png |
| fuji-superia-800-plus-1 | HaldCLUT/Color/Fuji/Fuji Superia 800 3 +.png |
| fuji-superia-800-plus-2 | HaldCLUT/Color/Fuji/Fuji Superia 800 4 ++.png |
| fuji-superia-hg-1600 | HaldCLUT/Color/Fuji/Fuji Superia HG 1600.png |
| fuji-superia-reala-100 | HaldCLUT/Color/Fuji/Fuji Superia Reala 100.png |
| fuji-superia-x-tra-800 | HaldCLUT/Color/Fuji/Fuji Superia X-Tra 800.png |
| kodak-ektar-100 | HaldCLUT/Color/Kodak/Kodak Ektar 100.png |
| kodak-elite-100-xpro | HaldCLUT/Color/Kodak/Kodak Elite 100 XPRO.png |
| kodak-portra-160 | HaldCLUT/Color/Kodak/Kodak Portra 160 2.png |
| kodak-portra-160-minus-1 | HaldCLUT/Color/Kodak/Kodak Portra 160 1 -.png |
| kodak-portra-160-plus-1 | HaldCLUT/Color/Kodak/Kodak Portra 160 3 +.png |
| kodak-portra-160-plus-2 | HaldCLUT/Color/Kodak/Kodak Portra 160 4 ++.png |
| kodak-portra-160-nc | HaldCLUT/Color/Kodak/Kodak Portra 160 NC 2.png |
| kodak-portra-160-nc-minus-1 | HaldCLUT/Color/Kodak/Kodak Portra 160 NC 1 -.png |
| kodak-portra-160-nc-plus-1 | HaldCLUT/Color/Kodak/Kodak Portra 160 NC 3 +.png |
| kodak-portra-160-nc-plus-2 | HaldCLUT/Color/Kodak/Kodak Portra 160 NC 4 ++.png |
| kodak-portra-160-vc | HaldCLUT/Color/Kodak/Kodak Portra 160 VC 2.png |
| kodak-portra-160-vc-minus-1 | HaldCLUT/Color/Kodak/Kodak Portra 160 VC 1 -.png |
| kodak-portra-160-vc-plus-1 | HaldCLUT/Color/Kodak/Kodak Portra 160 VC 3 +.png |
| kodak-portra-160-vc-plus-2 | HaldCLUT/Color/Kodak/Kodak Portra 160 VC 4 ++.png |
| kodak-portra-400 | HaldCLUT/Color/Kodak/Kodak Portra 400 2.png |
| kodak-portra-400-minus-1 | HaldCLUT/Color/Kodak/Kodak Portra 400 1 -.png |
| kodak-portra-400-plus-1 | HaldCLUT/Color/Kodak/Kodak Portra 400 3 +.png |
| kodak-portra-400-plus-2 | HaldCLUT/Color/Kodak/Kodak Portra 400 4 ++.png |
| kodak-portra-400-nc | HaldCLUT/Color/Kodak/Kodak Portra 400 NC 2.png |
| kodak-portra-400-nc-minus-1 | HaldCLUT/Color/Kodak/Kodak Portra 400 NC 1 -.png |
| kodak-portra-400-nc-plus-1 | HaldCLUT/Color/Kodak/Kodak Portra 400 NC 3 +.png |
| kodak-portra-400-nc-plus-2 | HaldCLUT/Color/Kodak/Kodak Portra 400 NC 4 ++.png |
| kodak-portra-400-uc | HaldCLUT/Color/Kodak/Kodak Portra 400 UC 2.png |
| kodak-portra-400-uc-minus-1 | HaldCLUT/Color/Kodak/Kodak Portra 400 UC 1 -.png |
| kodak-portra-400-uc-plus-1 | HaldCLUT/Color/Kodak/Kodak Portra 400 UC 3 +.png |
| kodak-portra-400-uc-plus-2 | HaldCLUT/Color/Kodak/Kodak Portra 400 UC 4 ++.png |
| kodak-portra-400-vc | HaldCLUT/Color/Kodak/Kodak Portra 400 VC 2.png |
| kodak-portra-400-vc-minus-1 | HaldCLUT/Color/Kodak/Kodak Portra 400 VC 1 -.png |
| kodak-portra-400-vc-plus-1 | HaldCLUT/Color/Kodak/Kodak Portra 400 VC 3 +.png |
| kodak-portra-400-vc-plus-2 | HaldCLUT/Color/Kodak/Kodak Portra 400 VC 4 ++.png |
| kodak-portra-800 | HaldCLUT/Color/Kodak/Kodak Portra 800 2.png |
| kodak-portra-800-minus-1 | HaldCLUT/Color/Kodak/Kodak Portra 800 1 -.png |
| kodak-portra-800-plus-1 | HaldCLUT/Color/Kodak/Kodak Portra 800 3 +.png |
| kodak-portra-800-plus-2 | HaldCLUT/Color/Kodak/Kodak Portra 800 4 ++.png |
| kodak-portra-800-high-contrast | HaldCLUT/Color/Kodak/Kodak Portra 800 HC.png |
| lomography-redscale-100 | HaldCLUT/Color/Lomography/Lomography Redscale 100.png |
| agfa-precisa-100 | HaldCLUT/Color/Agfa/Agfa Precisa 100.png |
| fuji-astia-100f | HaldCLUT/Color/Fuji/Fuji Astia 100F.png |
| fuji-astia-100f-generic | HaldCLUT/Color/Fuji/Fuji Astia 100 Generic.png |
| fuji-provia-100f | HaldCLUT/Color/Fuji/Fuji Provia 100F.png |
| fuji-provia-100f-generic | HaldCLUT/Color/Fuji/Fuji Provia 100 Generic.png |
| fuji-provia-400f | HaldCLUT/Color/Fuji/Fuji Provia 400F.png |
| fuji-provia-400x | HaldCLUT/Color/Fuji/Fuji Provia 400X.png |
| fuji-sensia-100 | HaldCLUT/Color/Fuji/Fuji Sensia 100.png |
| fuji-superia-200-xpro | HaldCLUT/Color/Fuji/Fuji Superia 200 XPRO.png |
| fuji-velvia-100 | HaldCLUT/Color/Fuji/Fuji Velvia 100 Generic.png |
| fuji-velvia-50 | HaldCLUT/Color/Fuji/Fuji Velvia 50.png |
| kodak-e100gx | HaldCLUT/Color/Kodak/Kodak E-100 GX Ektachrome 100.png |
| kodak-ektachrome-100-vs | HaldCLUT/Color/Kodak/Kodak Ektachrome 100 VS.png |
| kodak-ektachrome-100-vs-generic | HaldCLUT/Color/Kodak/Kodak Ektachrome 100 VS Generic.png |
| kodak-elite-chrome-200 | HaldCLUT/Color/Kodak/Kodak Elite Chrome 200.png |
| kodak-elite-chrome-400 | HaldCLUT/Color/Kodak/Kodak Elite Chrome 400.png |
| kodak-elite-color-200 | HaldCLUT/Color/Kodak/Kodak Elite Color 200.png |
| kodak-elite-color-400 | HaldCLUT/Color/Kodak/Kodak Elite Color 400.png |
| kodak-elite-extracolor-100 | HaldCLUT/Color/Kodak/Kodak Elite ExtraColor 100.png |
| kodak-kodachrome-200 | HaldCLUT/Color/Kodak/Kodak Kodachrome 200.png |
| kodak-kodachrome-25 | HaldCLUT/Color/Kodak/Kodak Kodachrome 25.png |
| kodak-kodachrome-64 | HaldCLUT/Color/Kodak/Kodak Kodachrome 64.png |
| kodak-kodachrome-64-generic | HaldCLUT/Color/Kodak/Kodak Kodachrome 64 Generic.png |
| lomography-x-pro-slide-200 | HaldCLUT/Color/Lomography/Lomography X-Pro Slide 200.png |
| agfa-apx-100 | HaldCLUT/Black-and-White/Agfa/Agfa APX 100.png |
| agfa-apx-25 | HaldCLUT/Black-and-White/Agfa/Agfa APX 25.png |
| fuji-neopan-1600 | HaldCLUT/Black-and-White/Fuji/Fuji Neopan 1600 2.png |
| fuji-neopan-1600-minus-1 | HaldCLUT/Black-and-White/Fuji/Fuji Neopan 1600 1 -.png |
| fuji-neopan-1600-plus-1 | HaldCLUT/Black-and-White/Fuji/Fuji Neopan 1600 3 +.png |
| fuji-neopan-1600-plus-2 | HaldCLUT/Black-and-White/Fuji/Fuji Neopan 1600 4 ++.png |
| fuji-neopan-acros-100 | HaldCLUT/Black-and-White/Fuji/Fuji Neopan Acros 100.png |
| ilford-delta-100 | HaldCLUT/Black-and-White/Ilford/Ilford Delta 100.png |
| ilford-delta-3200 | HaldCLUT/Black-and-White/Ilford/Ilford Delta 3200 2.png |
| ilford-delta-3200-minus-1 | HaldCLUT/Black-and-White/Ilford/Ilford Delta 3200 1 -.png |
| ilford-delta-3200-plus-1 | HaldCLUT/Black-and-White/Ilford/Ilford Delta 3200 3 +.png |
| ilford-delta-3200-plus-2 | HaldCLUT/Black-and-White/Ilford/Ilford Delta 3200 4 ++.png |
| ilford-delta-400 | HaldCLUT/Black-and-White/Ilford/Ilford Delta 400.png |
| ilford-fp4-plus-125 | HaldCLUT/Black-and-White/Ilford/Ilford FP4 Plus 125.png |
| ilford-hp5-plus-400 | HaldCLUT/Black-and-White/Ilford/Ilford HP5 2.png |
| ilford-hp5-plus-400-minus-1 | HaldCLUT/Black-and-White/Ilford/Ilford HP5 1 -.png |
| ilford-hp5-plus-400-plus-1 | HaldCLUT/Black-and-White/Ilford/Ilford HP5 3 +.png |
| ilford-hp5-plus-400-plus-2 | HaldCLUT/Black-and-White/Ilford/Ilford HP5 4 ++.png |
| ilford-hp5-plus-400-alt | HaldCLUT/Black-and-White/Ilford/Ilford HP5 Plus 400.png |
| ilford-hps-800 | HaldCLUT/Black-and-White/Ilford/Ilford HPS 800.png |
| ilford-pan-f-plus-50 | HaldCLUT/Black-and-White/Ilford/Ilford Pan F Plus 50.png |
| ilford-xp2-400 | HaldCLUT/Black-and-White/Ilford/Ilford XP2.png |
| kodak-bw-400-cn | HaldCLUT/Black-and-White/Kodak/Kodak BW 400 CN.png |
| kodak-hie | HaldCLUT/Black-and-White/Kodak/Kodak HIE (HS Infra).png |
| kodak-t-max-100 | HaldCLUT/Black-and-White/Kodak/Kodak T-Max 100.png |
| kodak-t-max-3200 | HaldCLUT/Black-and-White/Kodak/Kodak TMAX 3200 2.png |
| kodak-t-max-3200-minus-1 | HaldCLUT/Black-and-White/Kodak/Kodak TMAX 3200 1 -.png |
| kodak-t-max-3200-plus-1 | HaldCLUT/Black-and-White/Kodak/Kodak TMAX 3200 4 +.png |
| kodak-t-max-3200-plus-2 | HaldCLUT/Black-and-White/Kodak/Kodak TMAX 3200 5 ++.png |
| kodak-t-max-3200-alt | HaldCLUT/Black-and-White/Kodak/Kodak TMAX 3200 3 Alt.png |
| kodak-t-max-400 | HaldCLUT/Black-and-White/Kodak/Kodak T-Max 400.png |
| kodak-tri-x-400 | HaldCLUT/Black-and-White/Kodak/Kodak TRI-X 400 2.png |
| kodak-tri-x-400-minus-1 | HaldCLUT/Black-and-White/Kodak/Kodak TRI-X 400 1 -.png |
| kodak-tri-x-400-plus-1 | HaldCLUT/Black-and-White/Kodak/Kodak TRI-X 400 4 +.png |
| kodak-tri-x-400-plus-2 | HaldCLUT/Black-and-White/Kodak/Kodak TRI-X 400 5 ++.png |
| kodak-tri-x-400-alt | HaldCLUT/Black-and-White/Kodak/Kodak TRI-X 400 3 Alt.png |
| rollei-ir-400 | HaldCLUT/Black-and-White/Rollei/Rollei IR 400.png |
| rollei-ortho-25 | HaldCLUT/Black-and-White/Rollei/Rollei Ortho 25.png |
| rollei-retro-100-tonal | HaldCLUT/Black-and-White/Rollei/Rollei Retro 100 Tonal.png |
| rollei-retro-80s | HaldCLUT/Black-and-White/Rollei/Rollei Retro 80s.png |
| fuji-fp-100c | HaldCLUT/Color/Fuji/Fuji FP-100c 3.png |
| fuji-fp-100c-minus-2 | HaldCLUT/Color/Fuji/Fuji FP-100c 1 --.png |
| fuji-fp-100c-minus-1 | HaldCLUT/Color/Fuji/Fuji FP-100c 2 -.png |
| fuji-fp-100c-plus-1 | HaldCLUT/Color/Fuji/Fuji FP-100c 5 +.png |
| fuji-fp-100c-plus-2 | HaldCLUT/Color/Fuji/Fuji FP-100c 6 ++.png |
| fuji-fp-100c-plus-3 | HaldCLUT/Color/Fuji/Fuji FP-100c 8 +++.png |
| fuji-fp-100c-alt | HaldCLUT/Color/Fuji/Fuji FP-100c 4 Alt.png |
| fuji-fp-100c-plus-2-alt | HaldCLUT/Color/Fuji/Fuji FP-100c 7 ++ Alt.png |
| fuji-fp-100c-cool-minus-2 | HaldCLUT/Color/Fuji/Fuji FP-100c Cool 1 --.png |
| fuji-fp-100c-cool-minus-1 | HaldCLUT/Color/Fuji/Fuji FP-100c Cool 2 -.png |
| fuji-fp-100c-cool | HaldCLUT/Color/Fuji/Fuji FP-100c Cool 3.png |
| fuji-fp-100c-cool-plus-1 | HaldCLUT/Color/Fuji/Fuji FP-100c Cool 4 +.png |
| fuji-fp-100c-cool-plus-2 | HaldCLUT/Color/Fuji/Fuji FP-100c Cool 5 ++.png |
| fuji-fp-100c-negative | HaldCLUT/Color/Fuji/Fuji FP-100c Negative 3.png |
| fuji-fp-100c-negative-minus-2 | HaldCLUT/Color/Fuji/Fuji FP-100c Negative 1 --.png |
| fuji-fp-100c-negative-minus-1 | HaldCLUT/Color/Fuji/Fuji FP-100c Negative 2 -.png |
| fuji-fp-100c-negative-plus-1 | HaldCLUT/Color/Fuji/Fuji FP-100c Negative 4 +.png |
| fuji-fp-100c-negative-plus-2 | HaldCLUT/Color/Fuji/Fuji FP-100c Negative 5 ++.png |
| fuji-fp-100c-negative-plus-3 | HaldCLUT/Color/Fuji/Fuji FP-100c Negative 7 +++.png |
| fuji-fp-100c-negative-plus-2-alt | HaldCLUT/Color/Fuji/Fuji FP-100c Negative 6 ++ Alt.png |
| fuji-fp-3000b | HaldCLUT/Black-and-White/Fuji/Fuji FP-3000b 3.png |
| fuji-fp-3000b-minus-2 | HaldCLUT/Black-and-White/Fuji/Fuji FP-3000b 1 --.png |
| fuji-fp-3000b-minus-1 | HaldCLUT/Black-and-White/Fuji/Fuji FP-3000b 2 -.png |
| fuji-fp-3000b-plus-1 | HaldCLUT/Black-and-White/Fuji/Fuji FP-3000b 4 +.png |
| fuji-fp-3000b-plus-2 | HaldCLUT/Black-and-White/Fuji/Fuji FP-3000b 5 ++.png |
| fuji-fp-3000b-plus-3 | HaldCLUT/Black-and-White/Fuji/Fuji FP-3000b 6 +++.png |
| fuji-fp-3000b-high-contrast | HaldCLUT/Black-and-White/Fuji/Fuji FP-3000b HC.png |
| fuji-fp-3000b-negative | HaldCLUT/Black-and-White/Fuji/Fuji FP-3000b Negative 3.png |
| fuji-fp-3000b-negative-minus-2 | HaldCLUT/Black-and-White/Fuji/Fuji FP-3000b Negative 1 --.png |
| fuji-fp-3000b-negative-minus-1 | HaldCLUT/Black-and-White/Fuji/Fuji FP-3000b Negative 2 -.png |
| fuji-fp-3000b-negative-plus-1 | HaldCLUT/Black-and-White/Fuji/Fuji FP-3000b Negative 4 +.png |
| fuji-fp-3000b-negative-plus-2 | HaldCLUT/Black-and-White/Fuji/Fuji FP-3000b Negative 5 ++.png |
| fuji-fp-3000b-negative-plus-3 | HaldCLUT/Black-and-White/Fuji/Fuji FP-3000b Negative 6 +++.png |
| fuji-fp-3000b-negative-early | HaldCLUT/Black-and-White/Fuji/Fuji FP-3000b Negative Early.png |
| polaroid-664 | HaldCLUT/Black-and-White/Polaroid/Polaroid 664.png |
| polaroid-665 | HaldCLUT/Black-and-White/Polaroid/Polaroid 665 3.png |
| polaroid-665-minus-2 | HaldCLUT/Black-and-White/Polaroid/Polaroid 665 1 --.png |
| polaroid-665-minus-1 | HaldCLUT/Black-and-White/Polaroid/Polaroid 665 2 -.png |
| polaroid-665-plus-1 | HaldCLUT/Black-and-White/Polaroid/Polaroid 665 4 +.png |
| polaroid-665-plus-2 | HaldCLUT/Black-and-White/Polaroid/Polaroid 665 5 ++.png |
| polaroid-665-negative | HaldCLUT/Black-and-White/Polaroid/Polaroid 665 Negative 2.png |
| polaroid-665-negative-minus-1 | HaldCLUT/Black-and-White/Polaroid/Polaroid 665 Negative 1 -.png |
| polaroid-665-negative-plus-1 | HaldCLUT/Black-and-White/Polaroid/Polaroid 665 Negative 3 +.png |
| polaroid-665-negative-high-contrast | HaldCLUT/Black-and-White/Polaroid/Polaroid 665 Negative HC.png |
| polaroid-667 | HaldCLUT/Black-and-White/Polaroid/Polaroid 667.png |
| polaroid-669 | HaldCLUT/Color/Polaroid/Polaroid 669 3.png |
| polaroid-669-minus-2 | HaldCLUT/Color/Polaroid/Polaroid 669 1 --.png |
| polaroid-669-minus-1 | HaldCLUT/Color/Polaroid/Polaroid 669 2 -.png |
| polaroid-669-plus-1 | HaldCLUT/Color/Polaroid/Polaroid 669 4 +.png |
| polaroid-669-plus-2 | HaldCLUT/Color/Polaroid/Polaroid 669 5 ++.png |
| polaroid-669-plus-3 | HaldCLUT/Color/Polaroid/Polaroid 669 6 +++.png |
| polaroid-669-cold-minus-2 | HaldCLUT/Color/Polaroid/Polaroid 669 Cold 1 --.png |
| polaroid-669-cold-minus-1 | HaldCLUT/Color/Polaroid/Polaroid 669 Cold 2 -.png |
| polaroid-669-cold | HaldCLUT/Color/Polaroid/Polaroid 669 Cold 3.png |
| polaroid-669-cold-plus-1 | HaldCLUT/Color/Polaroid/Polaroid 669 Cold 4 +.png |
| polaroid-672 | HaldCLUT/Black-and-White/Polaroid/Polaroid 672.png |
| polaroid-690 | HaldCLUT/Color/Polaroid/Polaroid 690 3.png |
| polaroid-690-minus-2 | HaldCLUT/Color/Polaroid/Polaroid 690 1 --.png |
| polaroid-690-minus-1 | HaldCLUT/Color/Polaroid/Polaroid 690 2 -.png |
| polaroid-690-plus-1 | HaldCLUT/Color/Polaroid/Polaroid 690 4 +.png |
| polaroid-690-plus-2 | HaldCLUT/Color/Polaroid/Polaroid 690 5 ++.png |
| polaroid-690-cold-minus-2 | HaldCLUT/Color/Polaroid/Polaroid 690 Cold 1 --.png |
| polaroid-690-cold-minus-1 | HaldCLUT/Color/Polaroid/Polaroid 690 Cold 2 -.png |
| polaroid-690-cold | HaldCLUT/Color/Polaroid/Polaroid 690 Cold 3.png |
| polaroid-690-cold-plus-1 | HaldCLUT/Color/Polaroid/Polaroid 690 Cold 4 +.png |
| polaroid-690-cold-plus-2 | HaldCLUT/Color/Polaroid/Polaroid 690 Cold 5 ++.png |
| polaroid-690-warm-minus-2 | HaldCLUT/Color/Polaroid/Polaroid 690 Warm 1 --.png |
| polaroid-690-warm-minus-1 | HaldCLUT/Color/Polaroid/Polaroid 690 Warm 2 -.png |
| polaroid-690-warm | HaldCLUT/Color/Polaroid/Polaroid 690 Warm 3.png |
| polaroid-690-warm-plus-1 | HaldCLUT/Color/Polaroid/Polaroid 690 Warm 4 +.png |
| polaroid-690-warm-plus-2 | HaldCLUT/Color/Polaroid/Polaroid 690 Warm 5 ++.png |
| polaroid-polachrome | HaldCLUT/Color/Polaroid/Polaroid Polachrome.png |
| polaroid-px-100uv-plus | HaldCLUT/Color/Polaroid/Polaroid PX-100UV+ Warm 3.png |
| polaroid-px-100uv-plus-minus-2 | HaldCLUT/Color/Polaroid/Polaroid PX-100UV+ Warm 1 --.png |
| polaroid-px-100uv-plus-minus-1 | HaldCLUT/Color/Polaroid/Polaroid PX-100UV+ Warm 2 -.png |
| polaroid-px-100uv-plus-plus-1 | HaldCLUT/Color/Polaroid/Polaroid PX-100UV+ Warm 4 +.png |
| polaroid-px-100uv-plus-plus-2 | HaldCLUT/Color/Polaroid/Polaroid PX-100UV+ Warm 5 ++.png |
| polaroid-px-100uv-plus-plus-3 | HaldCLUT/Color/Polaroid/Polaroid PX-100UV+ Warm 6 +++.png |
| polaroid-px-100uv-plus-cold-minus-2 | HaldCLUT/Color/Polaroid/Polaroid PX-100UV+ Cold 1 --.png |
| polaroid-px-100uv-plus-cold-minus-1 | HaldCLUT/Color/Polaroid/Polaroid PX-100UV+ Cold 2 -.png |
| polaroid-px-100uv-plus-cold | HaldCLUT/Color/Polaroid/Polaroid PX-100UV+ Cold 3.png |
| polaroid-px-100uv-plus-cold-plus-1 | HaldCLUT/Color/Polaroid/Polaroid PX-100UV+ Cold 4 +.png |
| polaroid-px-100uv-plus-cold-plus-2 | HaldCLUT/Color/Polaroid/Polaroid PX-100UV+ Cold 5 ++.png |
| polaroid-px-100uv-plus-cold-plus-3 | HaldCLUT/Color/Polaroid/Polaroid PX-100UV+ Cold 6 +++.png |
| polaroid-px-680 | HaldCLUT/Color/Polaroid/Polaroid PX-680 3.png |
| polaroid-px-680-minus-2 | HaldCLUT/Color/Polaroid/Polaroid PX-680 1 --.png |
| polaroid-px-680-minus-1 | HaldCLUT/Color/Polaroid/Polaroid PX-680 2 -.png |
| polaroid-px-680-plus-1 | HaldCLUT/Color/Polaroid/Polaroid PX-680 4 +.png |
| polaroid-px-680-plus-2 | HaldCLUT/Color/Polaroid/Polaroid PX-680 5 ++.png |
| polaroid-px-680-cold-minus-2 | HaldCLUT/Color/Polaroid/Polaroid PX-680 Cold 1 --.png |
| polaroid-px-680-cold-minus-1 | HaldCLUT/Color/Polaroid/Polaroid PX-680 Cold 2 -.png |
| polaroid-px-680-cold | HaldCLUT/Color/Polaroid/Polaroid PX-680 Cold 3.png |
| polaroid-px-680-cold-plus-1 | HaldCLUT/Color/Polaroid/Polaroid PX-680 Cold 4 +.png |
| polaroid-px-680-cold-plus-2 | HaldCLUT/Color/Polaroid/Polaroid PX-680 Cold 5 ++.png |
| polaroid-px-680-cold-plus-2-alt | HaldCLUT/Color/Polaroid/Polaroid PX-680 Cold 6 ++ Alt.png |
| polaroid-px-680-warm-minus-2 | HaldCLUT/Color/Polaroid/Polaroid PX-680 Warm 1 --.png |
| polaroid-px-680-warm-minus-1 | HaldCLUT/Color/Polaroid/Polaroid PX-680 Warm 2 -.png |
| polaroid-px-680-warm | HaldCLUT/Color/Polaroid/Polaroid PX-680 Warm 3.png |
| polaroid-px-680-warm-plus-1 | HaldCLUT/Color/Polaroid/Polaroid PX-680 Warm 4 +.png |
| polaroid-px-680-warm-plus-2 | HaldCLUT/Color/Polaroid/Polaroid PX-680 Warm 5 ++.png |
| polaroid-px-70 | HaldCLUT/Color/Polaroid/Polaroid PX-70 3.png |
| polaroid-px-70-minus-2 | HaldCLUT/Color/Polaroid/Polaroid PX-70 1 --.png |
| polaroid-px-70-minus-1 | HaldCLUT/Color/Polaroid/Polaroid PX-70 2 -.png |
| polaroid-px-70-plus-1 | HaldCLUT/Color/Polaroid/Polaroid PX-70 4 +.png |
| polaroid-px-70-plus-2 | HaldCLUT/Color/Polaroid/Polaroid PX-70 5 ++.png |
| polaroid-px-70-plus-3 | HaldCLUT/Color/Polaroid/Polaroid PX-70 6 +++.png |
| polaroid-px-70-cold-minus-2 | HaldCLUT/Color/Polaroid/Polaroid PX-70 Cold 1 --.png |
| polaroid-px-70-cold-minus-1 | HaldCLUT/Color/Polaroid/Polaroid PX-70 Cold 2 -.png |
| polaroid-px-70-cold | HaldCLUT/Color/Polaroid/Polaroid PX-70 Cold 3.png |
| polaroid-px-70-cold-plus-1 | HaldCLUT/Color/Polaroid/Polaroid PX-70 Cold 4 +.png |
| polaroid-px-70-cold-plus-2 | HaldCLUT/Color/Polaroid/Polaroid PX-70 Cold 5 ++.png |
| polaroid-px-70-warm-minus-2 | HaldCLUT/Color/Polaroid/Polaroid PX-70 Warm 1 --.png |
| polaroid-px-70-warm-minus-1 | HaldCLUT/Color/Polaroid/Polaroid PX-70 Warm 2 -.png |
| polaroid-px-70-warm | HaldCLUT/Color/Polaroid/Polaroid PX-70 Warm 3.png |
| polaroid-px-70-warm-plus-1 | HaldCLUT/Color/Polaroid/Polaroid PX-70 Warm 4 +.png |
| polaroid-px-70-warm-plus-2 | HaldCLUT/Color/Polaroid/Polaroid PX-70 Warm 5 ++.png |
| polaroid-time-zero-expired | HaldCLUT/Color/Polaroid/Polaroid Time Zero (Expired) 4.png |
| polaroid-time-zero-expired-minus-3 | HaldCLUT/Color/Polaroid/Polaroid Time Zero (Expired) 1 ---.png |
| polaroid-time-zero-expired-minus-2 | HaldCLUT/Color/Polaroid/Polaroid Time Zero (Expired) 2 --.png |
| polaroid-time-zero-expired-minus-1 | HaldCLUT/Color/Polaroid/Polaroid Time Zero (Expired) 3 -.png |
| polaroid-time-zero-expired-plus-1 | HaldCLUT/Color/Polaroid/Polaroid Time Zero (Expired) 5 +.png |
| polaroid-time-zero-expired-plus-2 | HaldCLUT/Color/Polaroid/Polaroid Time Zero (Expired) 6 ++.png |
| polaroid-time-zero-expired-cold-minus-3 | HaldCLUT/Color/Polaroid/Polaroid Time Zero (Expired) Cold 1 ---.png |
| polaroid-time-zero-expired-cold-minus-2 | HaldCLUT/Color/Polaroid/Polaroid Time Zero (Expired) Cold 2 --.png |
| polaroid-time-zero-expired-cold-minus-1 | HaldCLUT/Color/Polaroid/Polaroid Time Zero (Expired) Cold 3 -.png |
| polaroid-time-zero-expired-cold | HaldCLUT/Color/Polaroid/Polaroid Time Zero (Expired) Cold 4.png |

## Mira original looks

These four looks are generated in code (`ProceduralLooks`) from Mira's own parametric transforms (tone curves, hue and saturation matrices, split colour balance). They are not derived from the collection above and are not part of the CC BY-SA material; they are covered by the app's own licence, PolyForm Noncommercial 1.0.0 (see LICENSE). They are inspired by published characteristic behavior of cinema negative, cinema print film and colour paper; no affiliation with Kodak or Fujifilm.

- vision3-500t (500T Tungsten)
- vision3-250d (250D Daylight)
- cinema-print (Cinema Print)
- color-paper (Color Paper)
