# BOMC engine: audit optimisasi berikutnya (ukuran + kecepatan ekspor)

**Tanggal:** 2026-11-11 · **Kelas bukti:** CLOUD FIXTURE LAB. Tidak menjalankan SketchUp, tidak memakai tekstur asli, dan tidak mengklaim apa pun secara native.
**Basis:** `main@4328778` (producer `bom_engine/`, BOMC 1.2). Draft PR #29 / candidate013 (`6725a0e`) **tidak** ikut diaudit, jadi optimisasi tekstur di branch itu perlu dicek ulang sebelum mengerjakan T1.
**Lingkup:** kerja *next step* menuju **BOMC 2.0**. Ini **tidak** dipakai di Research 01/02, dan tidak mengubah runtime, RBZ, atau kontrak format 1.2.
**Skrip yang bisa diulang:** [`tools/performance/bomc_lab/`](../../tools/performance/bomc_lab/). Python membutuhkan `numpy zstandard brotli`; Ruby membutuhkan `stackprof` (opsional).

Fixture yang dipakai: `skps/model-eval-exports/*.json` (RUMAH Y 121.833 face, SBOOST 2, house2) dan `skps/*_canonical.json` (presentation20 dengan 11.625 face, test). Fixture **canonical** adalah bentuk yang dihasilkan jalur SketchUp nyata (`CanonicalGraphBuilder`). Fixture **model-eval** adalah impor ulang dari JSON lama yang sudah dikuantisasi uint16.

Semua angka "stream" di bawah adalah ukuran stream yang diukur sendiri-sendiri. Angka itu **bukan** hasil implementasi end-to-end. Biaya decode di browser juga belum diukur.

---

## 0. Ringkasan eksekutif

| # | Temuan | Dampak terukur | Perubahan format? |
|---|---|---|---|
| **S1** | **Budget solver Visual/Research memilih kandidat *terbesar*** saat ukuran SKP diketahui, padahal kondisi itu berlaku di **setiap** ekspor nyata | RUMAH Y Visual **2.762.393 → 1.630.317 B (−41%)** tanpa melonggarkan toleransi | Tidak |
| **T1** | Tahap tekstur menghabiskan ~81% waktu ekspor model berat. Perbandingan piksel lossy dilakukan dengan loop Ruby per piksel | `compare()` = **2,4 detik per tekstur 4 MP per kandidat** (cloud Ruby 3.3); ada sekitar 6 kandidat per tekstur di Visual | Tidak |
| **S2** | Triangle bisa direkonstruksi dari loop: pola fan-corner, dan untuk quad hanya ada 4 pola exact | Stream triangle RUMAH Y **436 KB → 76 KB (deflate)** | Ya (BOMC 2.0) |
| **S3** | Normal bisa diturunkan dari posisi; cukup simpan daftar pengecualian | Visual: ~95% face tidak perlu normal. Exact: 46 KB → 8,3 KB | Ya |
| **S4** | Exact canonical: **100% koordinat ada di grid 1e-9 m**, sehingga integer nano bersifat lossless | Posisi Exact presentation20 62 KB → 36 KB (−42%). Normal, UV, dan transform punya pola yang sama | Ya |
| **S5** | Posisi Visual: grid 2⁻ᵏ mm + SoA + prediksi di dalam face | RUMAH Y 441 KB → 300 KB (−32%) | Ya |
| **S6** | UV Exact: weld per-vertex + integer nano | presentation20 220 KB → 107 KB (−51%) | Ya |
| **S7** | Codec section zstd/brotli | −12% (zstd19) dan −18% (brotli11) dibanding DEFLATE-9 | Ya (BOMC 2.0; codec 2/3 sudah reserved) |
| **T3** | Visibilitas scene menghitung ulang `page.layers.to_a`, `layer_folders`, dan `hidden_entities` untuk **setiap entity × setiap page** | Belum diukur native; kompleksitasnya O(entity × page × tag) | Tidak |
| **T5** | Compile: gerbang area memanggil Newell sumber ulang untuk setiap kandidat | Compile RUMAH Y **14,0 → 11,0 detik (−22%)**, output byte-identical | Tidak |

Proyeksi geometri RUMAH Y Visual kalau S1+S2+S3+S5+S7 digabung: **±2,76 MB → ±0,7 MB (−75%)**. Ini estimasi dari jumlah stream yang diukur terpisah.

---

## 1. Baseline yang diukur

### 1.1 Ukuran per section (RUMAH Y, Visual)

Ada dua kondisi: dengan `source_skp_bytes = 41.785.434` (kondisi ekspor nyata) dan tanpa ukuran sumber (kondisi "min-bytes").

| Section | Dengan ukuran SKP (nyata) | Tanpa ukuran SKP | Kandidat terpilih (nyata → min) |
|---|---:|---:|---|
| positions | 1.070.949 | 452.407 | float32/int32 → int16 (928/936 mesh) |
| normals | 855.480 | 349.019 | float32x3 → oct16x2 |
| topology | 715.564 | 715.564 | — |
| faces | 41.033 | 41.033 | — |
| strings | 36.326 | 36.326 | — |
| transforms | 21.606 | 14.477 | float64 → hybrid |
| **Total file** | **2.762.393** | **1.630.317** | |

Exact (RUMAH Y) = 3.752.530 B: normal float64 1,86 MB, posisi 1,06 MB (434 mesh memakai `float64_absolute`).

### 1.2 Waktu

Waktu cloud diukur dengan Ruby 3.3 dan 4 vCPU. Waktu native diambil dari historis di [milestone](../../MILESTONE_EVOLUTION_LINEUP_2026-09-25.md).

| Tahap | Waktu |
|---|---|
| `BOMCSizeGate.compile_candidate` (pack) RUMAH Y | 14,0 detik |
| Decode + `validate_profile!` | 2,8 detik + 3,7 detik |
| Native historis RUMAH Y Visual | 1.166 detik total, **945 detik di `SNAPSHOT_TEXTURES`**; Research 931 detik; Exact 404 detik |

Profil stackprof untuk pack:

| Penyumbang | Porsi |
|---|---:|
| `PositionCodec.newell_vector` / `area_gate` | 29% |
| GC | 20% |
| `Array#inspect` (fallback `graph.inspect` untuk source digest) | 4% |
| `ModelAdapter.from_model_eval` | 8% |
| Deflate kandidat | ~2% |

**Kesimpulan prioritas:** untuk mempercepat ekspor model berat, **tekstur dan snapshot SketchUp adalah tuas utama**. Compile cuma sekitar 1–5% dari total.

---

## 2. Celah ukuran

### S1 — Solver Visual/Research berinvestasi ke fidelity, bukan ke ukuran (BUG KEBIJAKAN, PRIORITAS 1)

`BOMCBudgetSolver.solve` memulai dari kandidat *highest fidelity* (`frontier[0]`, byte terbesar). Solver baru turun ke kandidat lebih kecil hanya kalau total masih di atas hard budget (90% SKP) atau preferred target (60% SKP).

Masalahnya, geometri RUMAH Y cuma sekitar 2,8 MB, sedangkan targetnya sekitar 25 MB. Akibatnya **tidak ada transisi sama sekali**: positions tetap float32, normals tetap float32x3, dan transform tetap float64. Padahal semua kandidat yang lebih kecil **sudah lolos toleransi profil** (int16 dan oct16 lolos gerbang Visual/Research). Fidelity tambahan itu tidak dijanjikan kontrak profil dan cuma menambah byte.

- **Perbaikan:** untuk Visual dan Research, pilih `min(stored_bytes)` di antara kandidat yang lolos `satisfies_profile_fidelity?`. Kebijakan ini sama dengan jalur `unconstrained` dan Exact. Budget tetap dipakai sebagai gerbang (gagal kalau tetap di atas hard ratio), bukan sebagai anggaran yang "dihabiskan".
- **Dampak:** −41% untuk RUMAH Y Visual. Efeknya paling besar di model **tanpa tekstur**, karena di sana geometri mendominasi.
- **Risiko:** rendah. Format tidak berubah, dan validator tetap memakai toleransi yang sama. Tes `test_bomc_budget_solver.rb` perlu diperbarui karena ekspektasinya kemungkinan mengunci perilaku lama.

### S2 — Triangle tidak perlu disimpan eksplisit

Klasifikasi face (exact sebagai *set* triangle):

| Fixture | Triangle | Quad / n-gon fan | Bukan fan | Ada hole |
|---|---:|---:|---:|---:|
| RUMAH Y | 60.366 | 57.041 | 4.170 | 253 |
| presentation20 | 5.699 | 5.518 | 359 | 49 |

Untuk quad, urutan triangle SketchUp (urutan triangle **dan** rotasi indeks) **hanya punya 4 pola**, yaitu `(k, k+2, k+3, k+2, k, k+1)` dengan k = 0..3. Datanya: 5.100 quad presentation20 hanya punya 4 pola, dan 54.995 quad RUMAH Y punya 4 pola dominan plus segelintir pola aneh.

Artinya urutan triangle Exact pun bisa disimpan dengan **2 bit per quad**.

| Encoding (RUMAH Y) | Deflate | zstd19 | brotli |
|---|---:|---:|---:|
| Sekarang: delta-zigzag indeks global | 436.417 | 392.286 | 367.874 |
| Indeks lokal-loop u8 | 90.858 | 69.350 | 65.033 |
| **Fan-corner byte/face + eksplisit untuk sisanya** | **76.485** | 64.461 | 55.654 |

- **Usulan blok TOPOLOGY v2:**
  - triangle face 3-vertex dihapus;
  - quad atau fan menyimpan kode corner `k`;
  - pola yang tidak cocok menyimpan indeks lokal-loop secara eksplisit (exception);
  - stream eksplisit untuk face dengan hole tetap ada.
  Untuk Exact, encoder memverifikasi urutan triangle sama persis; kalau tidak sama, face itu masuk exception.
- **Bonus kecepatan:** decoder (TS/Three.js) tidak perlu mem-parse 900 KB varint triangle.

### S3 — Normal diturunkan dari posisi

- **Canonical (normal asli SketchUp):** 100% face presentation20 berada dalam 0,1° dari Newell sumber, dan 1.478 di antaranya axis-aligned. Setelah posisi dikuantisasi grid Visual, **4,2%** face melampaui 0,1° (SBOOST 2 4,5%, house2 6,2%).
- **RUMAH Y:** angkanya 42,6%. Penyebabnya 22.494 face dengan luas < 1 mm², ditambah normal di sumber model-eval dihitung dari cross product 3 vertex pertama, bukan Newell.
- **Visual/Research:** decoder menghitung Newell dari posisi yang sudah di-decode. Encoder memverifikasi hasil ini per face dan menyimpan bitset pengecualian plus oct16 hanya untuk face pengecualian. Estimasinya: normals 349 KB → ±20–30 KB pada model canonical biasa, atau ±150 KB pada RUMAH Y.
- **Exact:** simpan residual `round9(stored) − round9(newell)` dalam unit nano. Hasilnya presentation20 **45.947 → 8.310 B (deflate)**; fixture `test` residualnya 0 untuk semua face.
- **Bonus:** normals adalah section geometri terbesar di Exact (1,86 MB pada RUMAH Y).

### S4 — Exact: semua koordinat canonical ada di grid integer

`CanonicalGraphBuilder` membulatkan semua angka ke 9 desimal (`round(9)`). Hasil uji: `round(x·1e9)/1e9 == x` **100%** untuk posisi canonical (presentation20 dan test). Jadi menyimpan integer nanometer bersifat **lossless bit-exact** terhadap graph yang divalidasi oleh Exact, dengan fallback per blok ke float64 kalau verifikasi gagal.

| Exact (deflate) | float64 sekarang | integer nano SoA delta | Hemat |
|---|---:|---:|---:|
| presentation20 positions | 62.454 | 36.380 | −42% |
| test positions | 25.899 | 11.989 | −54% |
| RUMAH Y positions (grid uint16 asli + min/scale) | 1.053.803 | 327.951 | −69% |

Normal, UV, dan transform canonical juga dibulatkan 9 desimal, jadi pola yang sama berlaku (lihat S3 dan S6).

**Catatan kontrak:** "Exact" di sini berarti identik dengan graph canonical yang sudah dibulatkan. Itu memang sudah menjadi acuan validator sekarang.

### S5 — Posisi Visual/Research: grid metrik + SoA + prediksi

| RUMAH Y (deflate) | Byte |
|---|---:|
| Sekarang: int16 bbox, AoS per mesh | 441.474 |
| A: int16, SoA delta per sumbu | 343.047 |
| B: grid 2⁻ᵏ mm adaptif (lolos gerbang posisi + area), SoA delta | 324.342 |
| **C: B + prediksi vertex sebelumnya / parallelogram di dalam face** | **299.958** (brotli 261.220) |

presentation20 juga turun dari 35.548 → 22.320 (−37%).

Grid metrik (bukan bbox/65534) membuat vertex yang sama di mesh berbeda punya integer yang sama, dan sumbu yang sejajar jadi delta 0. Satu catatan: grid harus tetap lolos gerbang luas dan orientasi yang sudah ada. Skrip lab sudah memakai gerbang yang sama.

### S6 — UV

- 100% UV depan adalah fungsi affine dari posisi lokal face (presentation20 11.625/11.625, test 111/111). Tapi tabel peta affine **kalah** dari encoding per-corner (presentation20 105 KB vs 98 KB), karena peta hampir unik per face (3.336 peta untuk 11.625 face). Ide ini **ditolak**.
- **Yang menang untuk Exact:** weld UV per vertex (pasangan vertex+UV yang sudah pernah muncul direferensikan ulang) plus integer nano. presentation20 **220.464 → 107.070 B (−51%)**, test 29.765 → 14.538.
- **Untuk Visual:** weld + kuantisasi int16 + delta.
- Tuas kecepatan di sisi SketchUp ada di T4.

### S7 — Codec entropi section

Section RUMAH Y Visual (file 2,76 MB):

| Codec | Total | Waktu kompres |
|---|---:|---:|
| DEFLATE-9 (sekarang) | 2.761.991 | 0,47 detik |
| DEFLATE-6 | 2.770.978 | 0,17 detik |
| zstd-3 | 2.680.971 | **0,02 detik** |
| zstd-19 | 2.423.275 (**−12%**) | 1,21 detik |
| brotli-11 | 2.261.926 (**−18%**) | 13,3 detik (terlalu lambat untuk ekspor interaktif) |

Kode codec 2 (Brotli) dan 3 (Zstd) sudah *reserved* di spesifikasi.

**Trade-off:**
- SketchUp Ruby tidak punya gem zstd. Pilihannya bundel `zstd.exe` dengan pola SHA-pinned yang sama seperti `cwebp.exe`, atau C-extension.
- Consumer browser (Editor/Rooms/Benchmark) butuh decoder zstd JS/WASM kecil, karena `DecompressionStream` belum menjamin dukungan zstd/brotli.
- **Rekomendasi:** zstd-19 untuk section besar, dan DEFLATE untuk fallback/legacy.

### S8 — Strings, meshes directory, dan kebersihan writer

- **Ada method ganda di `bomc_writer.rb`:** `build_string_dictionary` (baris 425 dan 1054) serta `build_strings_section` (baris 480 dan 1121). Definisi kedua yang berlaku, dan definisi itu **memasukkan stable ID material, definition, dan mesh ke dictionary production**, padahal kebalikannya dinyatakan di §6 `BOM_COMPILED_FORMAT.md`.
  - RUMAH Y: 6.037 string, raw 275 KB → 36 KB (deflate) / 22 KB (zstd).
  - Perlu dipastikan dulu ID mana yang benar-benar dibutuhkan scene/clip. Setelah itu, front-coding untuk string terurut (prefix bersama `node:definition:...`) dan pemangkasan ID yang tidak direferensikan.
- **MESHES:** 11 kolom uint32 per mesh. `face_start`, `edge_start`, dan semua offset bisa diturunkan dari prefix-sum count/length, jadi 7 dari 11 kolom bisa dihapus. Hematnya kecil (sekitar 9,5 KB di RUMAH Y).

### S9 — Tekstur: tuas ukuran terbesar untuk model bertekstur (belum terukur di cloud)

RUMAH Y Visual historis 17,96 MB, sementara geometrinya hanya ±2,8 MB. Jadi **sekitar 84% byte adalah tekstur**. Repo tidak memuat tekstur asli, sehingga ide-ide berikut masih **hipotesis** yang perlu matriks native:

1. **Cap resolusi berdasarkan texel density** untuk Visual. Resolusi yang dibutuhkan = luas UV yang benar-benar dipakai × `textureWidthM` × target px/m (misalnya 512 px/m untuk class B, 256 px/m untuk class C). Tekstur 4K yang dipakai sebagai ubin 30 cm tidak butuh 4096 px.
   Konsekuensinya, gerbang PSNR harus dibandingkan terhadap referensi yang sudah di-*downsample*, atau memakai metrik terpisah. Ini keputusan kebijakan owner.
2. **Lantai kualitas per kelas** memakai SSIM/MS-SSIM, bukan cuma PSNR dengan tangga tetap 80/90/95/100. Class C bisa turun ke q60–75.
3. **AVIF** biasanya 20–30% lebih kecil dari WebP pada kualitas yang sama. Ini butuh encoder bundel dan cek dukungan consumer.
4. **Dedup per pixel-SHA** sebelum staging (lihat T1). Ini mengurangi waktu, bukan ukuran: blob sudah di-dedup per SHA byte, tapi staging masih berjalan per material.

---

## 3. Celah kecepatan ekspor

### T1 — Staging tekstur (±81% waktu pada model berat)

Hasil microbench Ruby 3.3 untuk BGRA 2048² (4 MP):

| Operasi | Waktu |
|---|---:|
| `opaque?` (loop per piksel) | 0,25 detik |
| `compare` identik (fast path) | 0,02 detik |
| **`compare` lossy (jalur numerik)** | **2,38 detik** |
| SHA-256 piksel 16 MB | 0,08 detik |

Di Visual, satu tekstur bisa melewati: JPEG `save_file` + compare, lossless WebP + dwebp + ImageRep + compare, lalu tangga lossy q80→q100 (masing-masing encode, dwebp, `ImageRep.new`, compare). Itu berarti **sampai sekitar 6 compare lossy per tekstur** (±15 detik per tekstur 4 MP di cloud, kemungkinan lebih lambat di SketchUp), ditambah subprocess dan I/O PNG.

Usulan, diurutkan menurut dampak:

1. **Helper perbandingan native.** Bundel `bomc-imgdiff.exe` kecil yang SHA-pinned (seperti `cwebp.exe`) untuk menghitung MSE, max-channel, dan alpha dalam milidetik. Opsi lain, `cwebp -print_psnr`, menghindari dwebp, ImageRep, dan compare Ruby untuk kandidat lossy. Tapi **harus diverifikasi** dulu bahwa definisinya (ruang RGB vs YUV) setara dengan gerbang sekarang. Kalau tidak setara, pakai helper sendiri.
2. **Lossless WebP `-exact` cukup diverifikasi lewat SHA piksel** hasil decode (0,08 detik), bukan compare numerik.
3. **Dedup sebelum staging** berdasarkan `texture.filename`, dimensi, dan SHA piksel referensi. Material yang memakai gambar sama cukup di-stage sekali.
4. **Paralelkan subprocess.** Encode q80/90/95/100 bisa diluncurkan bersamaan, karena Ruby SketchUp single-thread tapi proses eksternal bisa jalan paralel. Bisa juga dengan pencarian biner kualitas.
5. **Lewati jalur JPEG di Visual** kalau WebP lossy sudah lolos. WebP hampir selalu lebih kecil dari JPEG pada PSNR yang sama.
6. **Cache persisten antar sesi dan antar profil.** Saat ini `candidate_cache` hanya hidup selama satu Export All. Kuncinya bisa (SHA piksel referensi, SHA encoder, revisi kebijakan, varian), disimpan di `%LOCALAPPDATA%`, dan sudah ada evidence-nya.
7. **`opaque?` tanpa loop per piksel.** Misalnya ekstraksi kanal alpha via `unpack` per baris lalu `String#count`/`delete`, atau dihitung oleh helper native di (1).

### T2 — Export All melakukan snapshot 3 kali

`export_all_profiles` memanggil `export()` untuk masing-masing visual, research, dan exact. Setiap pemanggilan menjalankan ulang `CanonicalGraphBuilder` (semua SketchUp API) dan staging tekstur penuh. Hanya hasil encode WebP dan JPEG-quality yang di-cache.

- **Usulan:** snapshot geometri satu kali dengan `preserve_hidden_geometry = true` sebagai superset. Turunkan universe per profil lewat filter, lalu compile tiga profil dari satu graph. Referensi `image_rep`, PNG staged, dan SHA piksel dipakai bersama.
- **Estimasi:** sekitar 2/3 waktu snapshot pada Export All.

### T3 — Visibilitas scene: kompleksitas kuadratik

`CanonicalGraphBuilder#each_entity` memanggil `SceneVisibilityResolver.exportable_universe?` untuk setiap entity. Fungsi itu mengevaluasi `effective_entity_visibility` untuk **setiap page**, dan di dalamnya:

- `effective_tag_visibility` menjalankan `page.layers.to_a`, `page.layer_folders.to_a`, dan `layer_folder_chain` per entity per page;
- kalau `get_drawingelement_visibility` mengembalikan nil, `page.hidden_entities.to_a` dibangun ulang per entity per page.

Selain itu, `resolve_scenes` dipanggil dua kali (di `initialize` dan di `build_scenes`).

- **Usulan:** prekomputasi per page satu kali, yaitu Hash layer → visible, Set hidden folder, dan Set `hidden_entities`. Visibilitas tag per (layer, page) di-memoize. Dengan begitu model dengan banyak scene (SBOOST scene-heavy) turun dari O(E·P·L) ke O(E·P).

### T4 — Snapshot face: kerja yang tidak dipakai BOMC

Untuk `output_format: 'bomc_v1_1'`, ada beberapa kerja per face yang hasilnya tidak dipakai adapter BOMC:

- `Traversal.extract_dicts(face)` per face (attribute dictionary);
- `Classifier.classify` dan `face.area` per face (BOMC menghitung ulang area);
- `semantic_for_face`;
- `checkpoint('Reading face vertices')` per vertex (murah, tapi menyumbang alokasi).

Usulannya: lewati semua itu dengan flag `lean_bomc_snapshot`.

Untuk Visual (setelah S2/S3), `face.mesh` bisa dilewati pada face cembung tanpa hole. Decoder membuat fan, dan Exact tetap memanggil `face.mesh`. Begitu juga UV Visual: cukup 3 panggilan UVQ per face lalu diekstrapolasi affine (100% affine terukur). Panggilan per-corner tetap dipakai di Exact.

### T5 — Compile (sudah diprototipe, byte-identical)

| Varian (RUMAH Y Visual, dengan ukuran SKP) | Waktu | Byte |
|---|---:|---:|
| Sekarang | 14,0 detik | 2.771.381 |
| + source digest dari `source_info.sha256` (bukan `graph.inspect`) | 14,0 detik | sama |
| + gerbang area: Newell sumber dihitung sekali per mesh, early-exit, lewati kandidat bit-identik | **11,0 detik** | sama |
| + DEFLATE-6 untuk estimasi kandidat | 11,2 detik | sama |

Ide lain:

- Hitung error hanya untuk kandidat yang mungkin menang (urutkan berdasarkan raw size, lalu berhenti).
- `appearance_metrics` dan `largest_texture_metrics` cukup untuk diagnostik, jangan di jalur panas.
- `SizeGate` bisa membangun ulang graph sampai 3 kali (standard/compact/maximum). Gunakan ulang kandidat yang sudah ter-cache dan cukup re-pack container-nya.
- `graph.inspect` untuk digest sebenarnya bisa memakan waktu dan memori besar pada graph canonical asli. Isi `source[:sha256]` dari `BOMCSizeGate.source_info`.

---

## 4. Ide yang diuji dan ditolak

| Ide | Hasil |
|---|---|
| Loop "high-watermark" (reorder vertex first-use) | RUMAH Y 269 KB vs 247 KB sekarang (deflate), lebih buruk |
| Tabel peta affine UV | Peta hampir unik per face, lebih besar dari per-corner |
| Brotli-11 saat ekspor | −18% tapi 13 detik di cloud untuk satu file; zstd-19 dipilih |
| Normal Exact diturunkan tanpa residual | Hanya 16% bit-exact (presentation20); butuh residual nano (S3) |

---

## 5. Urutan pengerjaan yang disarankan

**Keputusan owner (2026-11-11):** semua perubahan format digabung sebagai **BOMC 2.0** (major version), bukan 1.3.

Alasannya: S2–S8 mengubah layout beberapa section sekaligus, dan codec container zstd mengubah default kompresi. Header BOMC menolak major version yang tidak dikenal (`read_directory`: `major == VERSION_MAJOR`), jadi decoder 1.x akan gagal tegas (fail-closed) saat membaca file 2.0. Itu lebih jujur daripada minor bump yang diam-diam butuh fitur baru.

1. **Fase A — producer 1.2, tanpa perubahan format:** S1 → T1 (1, 2, 3, 5) → T3 → T5 → T2 → T4 (bagian yang tidak bergantung format). Hasilnya tetap file BOMC 1.2 yang valid bagi semua consumer yang ada.
2. **Fase B — spesifikasi dan referensi BOMC 2.0:**
   - `BOM_COMPILED_FORMAT_2_0.md` memuat TOPOLOGY v2 (S2), NORMALS derived + exceptions (S3), codec integer nano untuk Exact (S4/S6), grid metrik + prediksi (S5), dictionary string yang bersih + MESHES ramping (S8), dan codec section zstd sebagai default (S7) dengan DEFLATE sebagai fallback.
   - Encoder dan decoder referensi Ruby, plus fixture sintetis.
   - Consumer TS di Editor, Rooms, dan Benchmark harus bisa membaca **1.x dan 2.0** sebelum producer default ke 2.0. Selama transisi, producer tetap bisa mengeluarkan 1.2 (opsi profil/format).
3. **Fase C — eksperimen tekstur S9** (cap texel density, AVIF, gerbang SSIM). Butuh matriks native dan keputusan owner soal kebijakan kualitas Visual.

Setiap langkah tetap butuh gerbang native: matriks SketchUp pada build terpasang yang sama, fidelity sumber-vs-hasil, dan waktu per tahap. Ini sejalan dengan SIB-PERF-00 §7. Dokumen ini **tidak** menggantikan baseline native.
