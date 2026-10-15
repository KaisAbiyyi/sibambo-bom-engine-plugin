# Milestone — BOM Engine Evolution Lineup

**25 September 2026 · Status: kandidat terpasang, belum tersertifikasi lintas-model**

Tujuan lineup ini adalah membandingkan **empat generasi BOM Engine**, bukan empat kategori model SKP. SHA tiap generasi dicantumkan agar asal engine bisa diperiksa.

| Generasi | Engine | SHA asal / build | Status |
| --- | --- | --- | --- |
| E1 | JSON Visual / Standard / Full | `abdc70bbfd17` | Historis; belum tersertifikasi |
| E2 | Canonical JSON v3 + Gzip | `657d8671a66a` | Historis; belum tersertifikasi |
| E3 | CleanPKG | `d245b6873a99` | Historis; belum tersertifikasi |
| E4 | BOMC 1.2, evolusi dari `bd6782691ef8` | source-tree `a5816c9daf95` | Kandidat development; belum tersertifikasi |

## Track yang sudah dikerjakan

| Track | Hasil sekarang | Batas bukti |
| --- | --- | --- |
| Lineup & provenance | Keempat engine dikemas berdampingan; identitas SHA ditampilkan di menu/dialog. E1–E3 tetap generasi historis, E4 adalah engine yang dikembangkan. | Pemilihan lineup bukan peringkat performa yang sudah terukur. |
| Ketahanan ekspor | Kasus `model_transforms` E4 ditangani dengan fallback matriks 4×4 penuh dan pemeriksaan nilai tidak valid. Engine historis mendapat preflight transform; E3 menolak transform non-affine sejak awal. | Mencegah kegagalan/silent distortion yang diketahui, belum menjamin semua SKP berhasil. |
| Kontrol & UI | E4 punya Visual, Research, Exact, dan Export All; Export All berurutan dengan status parsial yang jujur. UI cream/maroon lebih ringkas. Batch Manual tetap 96–8192; Auto naik-turun menurut waktu kerja, dengan batas keselamatan 32768, bukan cap tetap 2048. | Exact tidak dijanjikan selalu lebih kecil; Auto belum dibenchmark pada matriks model luas. |
| Paket & integrasi | RBZ lineup dibuat dan dipasang untuk SketchUp 2026. SHA paket `18a5186b66a5`; source-tree terpasang cocok dengan manifest `a5816c9daf95`. Perubahan consumer BOMC sebelumnya sudah dikirim ke model-eval. | Perlu buka ulang SketchUp untuk memuat instalasi; status live URL tidak diperiksa ulang dalam milestone ini. |
| Verifikasi | Tes otomatis terkait: **86 lulus, 0 gagal**. Satu tes integritas arsip legacy terpisah masih gagal karena checksum artefak lama tidak cocok; arsip itu tidak diubah. | Belum ada sertifikasi fidelity, ukuran, dan waktu pada beragam SKP sesudah paket terbaru terpasang. |

## Perjalanan E4: dari `bd678269` sampai kandidat sekarang

Ini bagian utama pekerjaan. E4 **bukan** versi historis yang dibekukan: ia adalah kelanjutan kerja dari commit `bd6782691ef8ba98f9d3baab698bc1cd961ce393` (17 September 2026, “validate exact fidelity against identical geometry”). Identitas source-tree kandidat saat ini adalah `a5816c9daf958e40865917b234beb95cbafa37c0c035cb47f19bebd39cd9f0eb`; SHA base bukan SHA hasil akhir. Perubahannya masih di worktree producer, belum menjadi commit/release baru.

| Fase | Apa yang terjadi | Apa yang dikerjakan / dipelajari |
| --- | --- | --- |
| 1. Profil & validasi awal | Pada RUMAH L, ekspor sempat gagal di akhir (19/20), termasuk validasi Visual dan Exact atas *definitions*, normal, serta area. Angka “hampir selesai” ternyata belum berarti file valid. | Jalur validasi profil dan perbandingan terhadap geometri sumber diperbaiki; publikasi file tetap menunggu semua pemeriksaan lolos. Capture RUMAH L kemudian berhasil untuk Visual/Research/Exact, tetapi diberi status **pending certification**, bukan release. |
| 2. T7/T8 sebagai alat pembuktian | Dibuat kit capture yang memisahkan ekspor nyata di SketchUp, verifikasi decoder, metrik, dan keputusan sertifikasi. Pada matriks awal 6 kelas model, 5 sesi selesai dan satu model berat (RUMAH Y) gagal di Research. | Hasil lama tidak dihapus saat gagal; laporan menyimpan status parsial. Ini mengubah cara evaluasi: bukan “satu model lolos berarti engine universal”, melainkan matriks risiko lintas-model. T7/T8 adalah **jalur pengujian**, bukan empat generasi Evolution. |
| 3. Konflik ukuran vs fidelity | Beberapa Exact awal malah lebih besar dari SKP: model medium 2.93 MB vs sumber 2.16 MB, kompleks 6.66 MB vs 3.55 MB. Pada RUMAH Y, kegagalan lanjutan dan waktu tunggu panjang memperlihatkan bahwa ukuran bukan hanya soal kompresi geometri. | Size gate/diagnostik dibuat lebih jujur. Exact mempertahankan tuntutan fidelity dan **tidak menjanjikan file selalu lebih kecil**; Visual/Research mengejar anggaran ukuran hanya dengan kandidat yang lolos batas fidelity. Jika target tidak mungkin, laporkan sebab dan kandidat terbaik, jangan diam-diam membuang data. |
| 4. Penyelidikan tekstur Exact | Percobaan JPEG/WebP biasa tidak selalu aman untuk piksel asli. RUMAH Y punya tekstur besar; percobaan langsung di host pernah membuat SketchUp *Not Responding*. | Capture piksel asli dan JPEG dipisahkan dari pengolahan offline. Jalur JPEG Color Map (JCM) dibuat sebagai representasi *lossless* eksperimental dengan hash piksel dan decoder opt-in. Prepared map hanya boleh dipakai pada SKP/JPEG/piksel yang cocok; ini **bukan optimasi universal yang sudah disertifikasi**. |
| 5. Hasil ukuran yang nyata, tetapi bersyarat | Capture prepared Exact RUMAH Y menghasilkan 35,970,885 byte dari SKP 41,785,434 byte (hemat 5,814,549 byte). Matriks berikutnya menunjukkan Visual, Research, Exact dapat selesai pada model kecil, bertekstur, dan RUMAH Y. | Keberhasilan ini membuktikan ada jalan untuk Exact yang lebih kecil **pada kasus tersebut**, bukan hukum untuk setiap SKP. Status capture tetap `captured_pending_certification`; fidelity sumber-vs-hasil dan generalisasi masih harus diaudit. |
| 6. Biaya proses terukur | Pada matriks guarded sebelumnya, Visual RUMAH Y memakan 1,166 detik; sekitar 945 detik ada di `SNAPSHOT_TEXTURES`. Research 931 detik dan Exact 404 detik. | Bottleneck utama model berat ini adalah staging/validasi tekstur, bukan sekadar batch geometri 256. Kandidat tekstur kini diukur (ukuran, kualitas, alpha, kompatibilitas), pilihan yang tak lolos ditolak, dan Export All memakai cache kandidat bersama. Auto batch ditingkatkan, tetapi **belum terbukti** menghapus bottleneck tekstur itu. |
| 7. Kegagalan baru di luar model latihan | Pada RUMAH G, Visual gagal setelah sekitar 1,308 detik: `model_transforms` tidak punya kandidat yang lolos fidelity. Ini menunjukkan keberhasilan L/Y belum mencakup semua bentuk transform. | Akar masalah ditelusuri ke tiga codec transform 3×4 yang membuang komponen projective. Ditambah fallback Float64 4×4 penuh/hybrid serta guard nilai non-finite; tes producer/consumer lolos. **RUMAH G belum diuji ulang secara interaktif dengan paket terbaru**, jadi perbaikannya belum diklaim tersertifikasi di model itu. |
| 8. Produk kandidat, bukan lagi kit ad hoc | Permintaan akhirnya ditegaskan: Evolution adalah perjalanan engine JSON → Canonical → CleanPKG → BOMC, bukan daftar model uji. Dialog lama juga membingungkan soal SHA, status, batch, dan hasil. | E4 diberi Visual/Research/Exact/Export All, UI cream/maroon, identitas build, Auto yang dapat naik melewati 2048 hingga batas keselamatan 32768, serta status sukses/parsial/gagal yang berbeda. E1–E3 mendapat dialog sesuai kemampuan formatnya dan preflight transform. Paket lineup v6 dipasang; 86 tes otomatis terkait lulus. |

### Angka pembanding yang **bukan** sertifikasi paket final

Capture guarded sebelum paket lineup v6 memperlihatkan perbedaan skala dan batas klaim berikut. Ukuran di bawah adalah byte hasil ekspor profil, bukan ukuran aset browser hasil dekode.

| Model uji | SKP sumber | Visual | Research | Exact | Catatan |
| --- | ---: | ---: | ---: | ---: | --- |
| `test.skp` | 163,941 B | 47,211 B | 47,225 B | 47,154 B | Tiga ekspor selesai; model sangat kecil. |
| `house2.skp` | 440,016 B | 155,683 B | 165,554 B | 219,674 B | Tiga ekspor selesai; ada tekstur. |
| `RUMAH Y.skp` | 41,785,434 B | 17,957,535 B | 23,417,031 B | 35,891,925 B | Tiga ekspor selesai, namun Visual ~19.4 menit; belum certified. |

Sumber angka: `scratch/t7-matrix-capture-kit-20260920/**/session-status.json`, `scratch/exact-prepared-full-20260923-02/results/**/report.json`, dan `scratch/jcm-matrix-kit-20260924-v5-guarded/results/**/session-status.json`. Semua itu menguji build pada waktunya; **bukan** hasil uji lintas-model ulang untuk source-tree `a5816c9daf95` yang kini terpasang.

## Berikutnya sebelum disebut *ready*

1. Ulangi matriks pada **build terpasang yang sama**, termasuk RUMAH G/projective, model baru yang belum dipakai men-tune engine, dan E1–E3 sesuai kemampuan formatnya. Catat sukses/gagal, ukuran, waktu, dan alasan penolakan. Jangan ganti build di tengah matriks.
2. Bandingkan E4 terhadap SketchUp asli: geometri, definisi/instance, material/tekstur, UV, scene, dan ketiga profil. Prioritaskan `SNAPSHOT_TEXTURES` pada model berat; bandingkan Auto vs Manual dengan metrik, bukan asumsi bahwa batch lebih besar pasti lebih cepat.
3. Tetapkan gerbang rilis: tidak ada kerusakan diam-diam, kegagalan selalu diagnostik dan menjaga file lama, klaim ukuran dibuktikan per profil/model, serta paket/consumer/SHA diuji ulang bersama. Baru setelah itu ubah status dari kandidat menjadi tersertifikasi. Target realistisnya adalah **adaptif dan fail-safe**, bukan janji “semua input pasti berhasil dan selalu lebih kecil”.

**Artefak kandidat:** `D:/projects/sibambo/scratch/evolution-lineup-20260925-v6-all-auto/sibambo_bom_engine_evolution_lineup.rbz` · manifest di folder yang sama. Perubahan producer masih berada di worktree; milestone ini bukan klaim bahwa release sudah selesai.

## Peta workspace dan perapian (25 September 2026)

Titik masuk baru adalah [`../README.md`](../README.md). **Producer aktif** tetap `D:/projects/sibambo/bom_engine_plugin/` (source E4 worktree); **consumer web aktif** tetap `D:/projects/sibambo/model-eval/` (`main`). `model-eval-old/`, `bom_engine_plugin_clean_build_20260831/`, worktree audit, dan checkout `temp-*` **bukan** jalur aktif. Source producer, paket RBZ yang terpasang di SketchUp, source consumer, dan deployment live adalah empat keadaan berbeda; peta ini tidak menyamakan SHA atau statusnya.

Perapian fisik awal: 16 Markdown + 2 JSON catatan root dipindah ke [`../docs/worklogs/`](../docs/worklogs/), dan 5 RBZ lama ke arsip installer. Tautan relatif pada catatan yang dipindah diperbaiki dan diperiksa. Repo aktif, instalasi SketchUp, serta output kandidat **tidak dipindah/dihapus**.

**Perapian tahap 2:** Root mengutamakan tiga repo aktif (`bom_engine_plugin`, `model-eval`, `model-viewer`), `docs`, dan [`../outputs/`](../outputs/). Evolution v6 disalin ke `outputs/2026-09-25-current-candidates/evolution-lineup/` dengan SHA paket tetap `18a5186b66a5`. Paket **individual** BOMC 1.2 dibangun dari source runtime terkini ke folder saudara, tree SHA `34b2e377ee05`, RBZ SHA `bf143f7e8d8e`; paket ini **belum diinstal atau diuji di SketchUp**. Sebanyak 97 RBZ lama disalin ke `outputs/2026-09-25-imported-history/` per kategori dengan katalog SHA; file asal tidak dihapus. Tanggal folder output menandai **pengumpulan**, bukan tanggal build.

**Perapian tahap 3, berdasarkan masukan pengguna:** menyembunyikan banyak folder satu per satu ternyata tetap membuat root ramai bila Windows *Show hidden items* aktif. Folder lama yang bisa dipindah dikumpulkan secara fisik ke [`../_archive_2026-09-25/`](../_archive_2026-09-25/), termasuk `artifacts/legacy-installers/`, clone lama, tiga worktree historis, backup, baseline RBZ, dan checklist T8. Metadata worktree yang dipindah diverifikasi. Hanya folder induk arsip yang memiliki atribut Hidden. `scratch/` dan `model-eval-old/` masih di root, **tidak disembunyikan**, karena Windows menolak pemindahannya (penyebab pastinya belum dipastikan); keduanya memuat path capture yang dipin. Pemindahan parsial `scratch/` dikembalikan agar tidak meninggalkan kit terbelah. Ini navigasi workspace, **bukan** promosi status rilis atau bukti deployment baru. Rincian dan path aktual ada di [`../docs/workspace-archive.md`](../docs/workspace-archive.md).

## Update 28 September 2026 — E4 baru dipasang di lineup Evolution

Atas koreksi pengguna, E4 BOMC terbaru dipasang **di dalam** extension Evolution, bukan sebagai extension individual yang berdiri sendiri. Paket baru mempertahankan E1–E3 dan mengganti E4 source-tree `a5816c9daf95` dengan `b41ca09fa65acaa94195f6f74efdbc93497c7353712c8485a558e610f998f423`. RBZ SHA-256: `3e646aaf276a167aa9d90946eae22585eb6fa260f3c1ff9e10009a95193311ec`. Paket lama Evolution disimpan di `evolution_lineup_backup_20260928-164443_a5816c9daf95` dan extension individual source identity `3ca9bfa66cd7` dipindahkan ke `.bom_engine_backups/individual-integrated-into-evolution-20260928-3ca9bfa66cd7`.

Paket dan tree folder terpasang lolos pemeriksaan SHA; installer test **2 lulus, 0 gagal** dan build/load test lineup **2 lulus, 0 gagal**. SketchUp tertutup saat install dan belum menjalankan menu atau ekspor E4 baru. Status tetap `candidate_pending_cross_model_validation`; lihat [manifest paket terbaru](../outputs/2026-09-28-current-candidates/evolution-lineup/manifest.json), [receipt instalasi](../outputs/2026-09-28-current-candidates/evolution-lineup/install-report-20260928-165033.json), dan [review implementasi](../IMPLEMENTATION_REVIEW_2026-09-28_EVOLUTION-E4-REPLACEMENT_v1.0.md).

## Update 15 Oktober 2026 — profile parity candidate

Evolution sekarang memakai satu current capture/runtime untuk seluruh active lineup, tetapi mempertahankan writer yang berbeda: **E1 JSON 2.2, E2 Canonical JSON 3.1 + Gzip, E3 CleanPKG 1.1, dan E4 BOMC 1.2**. Keempat slot menawarkan **Visual, Research, Exact**. E1–E3 tidak lagi memakai snapshot historis sebagai active exporter; historical commit pins tetap disimpan sebagai provenance baseline dan Benchmark masih membaca file lama.

Kandidat package v2 dibangun ke [`../outputs/2026-10-15-evolution-profile-parity/evolution-lineup/`](../outputs/2026-10-15-evolution-profile-parity/evolution-lineup/). Shared runtime, E4 row, dan kedua `BUILD_SHA.txt` cocok pada source-tree `ebfa936e6b202eac40f01dc8566d55e00c265032857f4f38b92d1610693024d0`. SHA-256 RBZ adalah `11f3a508bf6adc3493ae0219d248e8b91b34e079ec1fa43760874ccffbf7e07a`. Installer berhasil pada temporary Plugins directory, termasuk compatibility package-v1→v2; **paket ini belum dipasang ke SketchUp pengguna**.

Writer Ruby menghasilkan matriks sintetis E1–E3 3×3 dan Benchmark membaca ulang semuanya dengan texture asset, material/color/alpha, scene, clip plane, occurrence, dan source-tree provenance. Chromium parity matrix **12/12 lulus**: sembilan E1–E3 rows plus E4 Visual/Research/Exact. Ini bukti interoperability sintetis, bukan pengganti ekspor SketchUp nyata atau visual acceptance terhadap source model.

Status tetap **candidate_pending_cross_model_validation**. Gerbang berikutnya adalah install/restart SketchUp, ekspor corpus nyata 5 model × 4 format × 3 profil, lalu perbandingan E1–E3 dengan E4 pada profile/camera yang sama untuk geometry, mirror/scale, front/back material, UV, texture color/alpha, scene dan clip. Ukuran, waktu, fidelity lintas-model dan certification belum diklaim.
