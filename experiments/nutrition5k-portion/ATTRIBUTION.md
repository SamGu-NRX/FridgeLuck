# Attribution — Nutrition5k data used in this experiment

All data in `data/` (targets, splits) and all imagery referenced by the pipeline is taken
from the public **Nutrition5k** dataset (Google Research), downloaded from the public Google
Cloud Storage bucket `gs://nutrition5k/` on 2026-10-09. The selective fetch script
(`src/download_nutrition5k.py`) recorded a per-file sha256 manifest; 6,524 files, 0 errors.

License, quoted verbatim from the bucket's `README.md` as fetched on 2026-10-09:

> We release all Nutrition5k data under the [Creative Commons V4.0](https://creativecommons.org/licenses/by/4.0/) license.
> You are free to share and adapt this data for any purpose, even commercially. If you found
> this dataset useful, please consider citing our
> [CVPR 2021 paper](https://arxiv.org/pdf/2103.03375.pdf).

Citation, quoted verbatim from the same `README.md`:

```bibtex
@inproceedings{thames2021nutrition5k,
  title={Nutrition5k: Towards Automatic Nutritional Understanding of Generic Food},
  author={Thames, Quin and Karpur, Arjun and Norris, Wade and Xia, Fangting and Panait, Liviu and Weyand, Tobias and Sim, Jack},
  booktitle={Proceedings of the IEEE/CVF Conference on Computer Vision and Pattern Recognition},
  pages={8903--8911},
  year={2021}
}
```

What was fetched (unmodified): `dish_metadata_cafe1.csv`, `dish_metadata_cafe2.csv`,
`ingredients_metadata.csv`, `rgb_train_ids.txt`, `rgb_test_ids.txt`,
`depth_train_ids.txt`, `depth_test_ids.txt`, `dish_ids_all.txt`, `dish_ids_cafe1.txt`,
`dish_ids_cafe2.txt`, the bucket `README`/`README.md`, the official
`compute_eval_statistics.py`, and per-dish overhead imagery (`rgb.png`, `depth_raw.png`
where present). No side-angle video data was fetched.

This experiment reports `MAE_%` exactly as computed by the official
`compute_eval_statistics.py` (downloaded unmodified; a parity test in
`src/test_pipeline.py` executes the downloaded script itself).

No Nutrition5k data is redistributed in this repository: the scripts re-download from the
public bucket on demand; `data/` contains only derived aggregates (per-dish target tables,
audits) built from it.
