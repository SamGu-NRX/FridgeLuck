# Packet A — real amounts for band rcp-000167..rcp-000376

Packet `burst11-fridgeluck-recipe-amounts-a`, measured at base alpha `ef236fc`.

The amounts set is the shipped bundle's band recipes with any ingredient line
whose `assumed_staple` is false and whose `quantity.kind` is `unknown`: at base
that is **86 recipes and 118 lines**. This packet measures **103** of those lines
and leaves **15** `to taste` with a reason: the packet rule keeps `to taste` only
for seasoning, garnish and heat (salt, chiles, finishing herbs, whole spices).

Three recipes whose titles name molasses but whose lines lacked it
(rcp-000194, rcp-000199, rcp-000201) also gain a molasses line plus a step edit
that uses it; those set `changes_rights_pin: true` because the rights pin is a
SHA-256 of ingredient names.

Before/after nutrition is compiled with the shipped compiler
(`compile_bundle.compile_recipe` — the same `nutrition_for` the bundle ships),
never re-implemented. `before` compiles the original corpus record and reproduces
the bundle's shipped numbers; `after` compiles the fixed record.

Six recipes land outside the compile bar with the reason recorded in the fix
file's `changes` entries: rcp-000247 and rcp-000330 (kcal outside the 150-1300 bar); rcp-000282,
rcp-000305, rcp-000319 and rcp-000351 (sodium above the 2300 mg bar) — in every case the packet
keeps the measured line true (a cook's portion of the title's protein or olive)
and the explanation names where the exceedance actually sits.

| catalog id | corpus id | recipe | serves | kcal/serving before → after | protein g before → after | sodium mg before → after | lines kept to taste |
|---|---|---|---|---|---|---|---|
| rcp-000169 | fl-original-0003 | Stacked Blueberry Pancakes with Whipped Butter | 4 | 413.8 → 437.8 | 13.2 → 13.4 | 786.6 → 786.6 |  |
| rcp-000172 | fl-original-0006 | Apple-Cinnamon Baked Oatmeal Squares | 6 | 174.3 → 202.8 | 9.3 → 9.4 | 238.7 → 239.7 |  |
| rcp-000173 | fl-original-0007 | Blueberry Baked French Toast with Vanilla Milk | 4 | 313.5 → 337.5 | 14.8 → 15.1 | 381.5 → 381.5 |  |
| rcp-000175 | fl-original-0009 | Deli-Style Tuna Salad on Toast | 2 | 179.0 → 312.6 | 8.0 → 37.4 | 277.8 → 347.8 |  |
| rcp-000177 | fl-original-0011 | Sunday Roast Chicken Salad Wrap | 2 | 155.7 → 314.7 | 6.0 → 29.8 | 322.8 → 419.4 |  |
| rcp-000178 | fl-original-0012 | Smashed Chickpea Salad Sandwich | 2 | 858.6 → 863.5 | 44.8 → 45.0 | 321.0 → 458.2 |  |
| rcp-000180 | fl-original-0014 | Smoky Black Bean Burger Patties | 4 | 246.9 → 306.2 | 12.5 → 14.5 | 20.7 → 130.5 |  |
| rcp-000182 | fl-original-0016 | Chicken & Brown Rice Soup | 4 | 436.5 → 440.0 | 34.9 → 35.1 | 957.9 → 977.9 | bay leaves — a bay leaf is a seasoning leaf, the packet rule's to-taste case |
| rcp-000184 | fl-original-0018 | Old-Fashioned Chicken Noodle Soup | 6 | 923.1 → 925.9 | 53.0 → 53.2 | 929.9 → 945.9 |  |
| rcp-000188 | fl-original-0022 | Sloppy Joe Sliders with Pickled Onion | 4 | 249.5 → 383.0 | 22.3 → 27.0 | 79.4 → 304.4 |  |
| rcp-000189 | fl-original-0023 | Cast-Iron Flank Steak with Garlic Butter | 3 | 74.7 → 439.2 | 0.3 → 44.0 | 824.6 → 1379.6 | rosemary — a finishing herb in the baste, per the packet rule |
| rcp-000191 | fl-original-0025 | Cajun Catfish with Skillet Corn | 3 | 137.2 → 519.7 | 3.9 → 24.1 | 42.5 → 669.5 |  |
| rcp-000193 | fl-original-0027 | Sheet-Pan Sausage & Cabbage Supper | 4 | 155.7 → 472.7 | 3.2 → 21.4 | 24.8 → 790.8 |  |
| rcp-000194 | fl-original-0028 | Meatloaf with Molasses Glaze | 4 | 266.6 → 369.8 | 23.8 → 26.0 | 678.1 → 894.1 |  · rights pin broken (molasses line added) |
| rcp-000195 | fl-original-0029 | Crunchy Baked Cod with Dill Tartar Sauce | 3 | 424.7 → 524.9 | 22.4 → 25.7 | 646.1 → 909.9 |  |
| rcp-000197 | fl-original-0031 | Oven-Fried Drumsticks with Cornmeal Crust | 4 | 92.0 → 488.0 | 2.5 → 49.5 | 2.0 → 924.8 | hot sauce — a dash of heat in the marinade, per the packet rule; the buffalo-style sauce case (rcp-000208) is measured instead |
| rcp-000198 | fl-original-0032 | Skillet Pork Chops with Apples & Cider | 3 | 414.5 → 499.1 | 31.7 → 32.0 | 730.0 → 734.4 |  |
| rcp-000199 | fl-original-0033 | Backyard Beef Chili with Molasses | 6 | 424.4 → 446.1 | 30.3 → 30.3 | 267.1 → 269.9 | chili powder — a heat seasoning, per the packet rule · rights pin broken (molasses line added) |
| rcp-000200 | fl-original-0034 | Sunday Pot Roast with Root Vegetables | 6 | 123.9 → 573.9 | 3.1 → 55.0 | 36.2 → 796.2 | rosemary — a braise seasoning herb, per the packet rule |
| rcp-000201 | fl-original-0035 | Slow-Cooker Molasses Pulled Pork | 8 | 30.3 → 463.0 | 0.6 → 41.9 | 4.2 → 374.5 |  · rights pin broken (molasses line added) |
| rcp-000202 | fl-original-0036 | Weeknight Chicken Tortilla Skillet | 4 | 503.2 → 621.2 | 38.9 → 40.6 | 620.9 → 702.9 |  |
| rcp-000203 | fl-original-0037 | Diner Tuna Melt with Pickles | 2 | 340.7 → 473.6 | 13.9 → 43.3 | 499.8 → 675.0 |  |
| rcp-000204 | fl-original-0038 | Buttermilk Ranch Chicken Salad | 3 | 197.7 → 219.9 | 28.0 → 29.8 | 102.4 → 151.6 | chives — a finishing herb, per the packet rule |
| rcp-000205 | fl-original-0039 | Maple-Dijon Roast Salmon with Green Beans | 3 | 381.4 → 412.4 | 30.7 → 32.5 | 89.9 → 95.9 |  |
| rcp-000206 | fl-original-0040 | Turkey & Cranberry Pressed Sandwich | 2 | 336.7 → 535.6 | 13.3 → 36.4 | 518.4 → 602.3 |  |
| rcp-000208 | fl-original-0042 | Buffalo Chicken Lettuce Cups | 3 | 172.3 → 210.1 | 19.9 → 21.3 | 121.0 → 708.2 |  |
| rcp-000213 | fl-original-0047 | Skillet Chicken and Chorizo Rice | 2 | 363.1 → 567.7 | 32.7 → 44.3 | 642.5 → 1232.3 |  |
| rcp-000221 | fl-original-0055 | Apricot and Olive Braised Chicken with Warm Spices | 2 | 441.5 → 687.4 | 31.0 → 31.2 | 481.6 → 483.3 |  |
| rcp-000225 | fl-original-0059 | Mediterranean Tuna and White Bean Salad | 2 | 369.7 → 462.5 | 11.9 → 32.3 | 372.0 → 412.0 |  |
| rcp-000227 | fl-original-0061 | Turmeric and Cilantro Masala Omelette | 2 | 282.1 → 282.1 | 16.8 → 16.8 | 233.3 → 233.3 | green chili — heat, per the packet rule |
| rcp-000228 | fl-original-0062 | Lemony Poha with Peanuts | 2 | 237.2 → 237.2 | 6.1 → 6.1 | 38.3 → 38.3 |  |
| rcp-000232 | fl-original-0066 | Punjabi-Style Chole with Brown Rice | 2 | 1025.0 → 1025.0 | 43.0 → 43.0 | 54.6 → 54.6 | ground coriander — a ground spice, per the packet rule |
| rcp-000237 | fl-original-0071 | Ricotta and Honey Toast with Thyme | 2 | 132.6 → 245.1 | 2.9 → 8.5 | 135.6 → 218.1 |  |
| rcp-000238 | fl-original-0072 | Cocoa and Espresso Morning Oats | 2 | 279.2 → 296.3 | 14.6 → 16.1 | 106.9 → 108.5 |  |
| rcp-000247 | fl-original-0081 | Almond and Honey Yogurt Bowl | 2 | 1525.9 → 1588.3 | 71.0 → 71.4 | 125.5 → 125.7 |  |
| rcp-000256 | fl-original-0090 | Potato and Chorizo Breakfast Tacos | 2 | 471.9 → 727.6 | 19.6 → 34.1 | 188.8 → 926.1 |  |
| rcp-000268 | fl-original-0102 | Tuna and Pea Pasta Gratin with Cheddar Crust | 2 | 556.3 → 649.1 | 22.5 → 42.9 | 1139.9 → 1179.9 |  |
| rcp-000270 | fl-original-0104 | Eggplant and Artichoke Rice with Lemon-Oregano Oil | 2 | 296.6 → 296.6 | 5.3 → 5.3 | 1817.8 → 1817.8 |  |
| rcp-000272 | fl-original-0106 | Spring Fattoush with Peas and Crisp Pita | 2 | 438.2 → 458.2 | 10.8 → 13.0 | 916.8 → 918.8 |  |
| rcp-000273 | fl-original-0107 | Eggplant and Bacon Rigatoni with Chilli Crumbs | 2 | 393.6 → 631.6 | 13.6 → 29.6 | 439.4 → 1324.4 |  |
| rcp-000274 | fl-original-0108 | Black Bean and Pineapple Salad with Cumin-Lime Dressing | 2 | 357.8 → 417.8 | 19.2 → 19.6 | 595.7 → 595.7 |  |
| rcp-000278 | fl-original-0112 | Red Onion and Anchovy Pasta with Lemon Breadcrumb Topping | 2 | 503.2 → 534.7 | 11.3 → 15.6 | 403.3 → 953.5 |  |
| rcp-000279 | fl-original-0113 | Cardamom Chicken with Lime and Basmati | 2 | 360.1 → 360.1 | 38.9 → 38.9 | 1167.0 → 1167.0 | green cardamom pods, crushed — a whole spice seasoning, per the packet rule |
| rcp-000282 | fl-original-0116 | Creamy Celery Soup with Toasted Almonds | 2 | 397.2 → 418.2 | 8.4 → 9.4 | 2272.4 → 2392.4 |  |
| rcp-000284 | fl-original-0118 | Chicken and Chorizo Ragu with Rigatoni | 2 | 405.2 → 575.7 | 31.5 → 41.2 | 352.6 → 844.1 |  |
| rcp-000287 | fl-original-0121 | Chicken and Leek Brown-Rice Bowl | 2 | 591.9 → 657.9 | 34.2 → 35.4 | 775.9 → 889.1 |  |
| rcp-000290 | fl-original-0124 | Skillet Chicken Parmesan for Two | 2 | 698.3 → 816.8 | 57.8 → 61.8 | 1551.3 → 1770.9 |  |
| rcp-000294 | fl-original-0128 | Coconut Squash Dhansak with Spinach | 2 | 761.7 → 851.7 | 26.1 → 28.1 | 1298.8 → 1306.8 |  |
| rcp-000295 | fl-original-0129 | Seared Cod with Cucumber, Avocado and Mango Salsa | 2 | 533.0 → 578.0 | 22.7 → 23.4 | 1229.9 → 1230.6 |  |
| rcp-000296 | fl-original-0130 | Crab-Tossed Linguine with Chilli, Parsley and Lemon | 2 | 378.5 → 440.7 | 7.2 → 20.6 | 1136.0 → 1558.2 |  |
| rcp-000301 | fl-original-0135 | Sticky Cola-Glazed Chicken Thighs | 2 | 357.5 → 399.5 | 48.9 → 48.9 | 1424.2 → 1427.2 |  |
| rcp-000303 | fl-original-0137 | Slow-Braised Duck Ragu with Swede and Pappardelle | 2 | 313.4 → 902.1 | 11.3 → 79.6 | 1623.3 → 1913.3 |  |
| rcp-000305 | fl-original-0139 | Bacon and Pea Risotto | 2 | 626.5 → 864.5 | 24.6 → 40.6 | 2263.7 → 3148.7 |  |
| rcp-000306 | fl-original-0140 | Egg-Fried Noodles with Crisp Veg and Beansprouts | 2 | 771.8 → 786.8 | 30.4 → 31.9 | 1019.4 → 1022.4 |  |
| rcp-000307 | fl-original-0141 | Salmon Nicoise with Dijon Vinaigrette | 2 | 735.2 → 935.2 | 42.9 → 44.2 | 1083.9 → 1088.8 |  |
| rcp-000309 | fl-original-0143 | Green Goddess Chicken Slaw | 2 | 511.0 → 515.2 | 50.2 → 50.4 | 781.7 → 805.7 |  |
| rcp-000310 | fl-original-0144 | Seared Halloumi, Carrot and Orange Salad | 2 | 222.7 → 484.7 | 2.3 → 16.7 | 373.7 → 926.7 |  |
| rcp-000316 | fl-original-0150 | Crispy Gnocchi with Beans and Spinach | 2 | 439.3 → 795.3 | 21.8 → 38.9 | 730.5 → 1256.5 |  |
| rcp-000319 | fl-original-0153 | Winter Squash and Borlotti Soup with Farro | 2 | 436.1 → 503.6 | 19.0 → 20.5 | 2351.9 → 2357.9 |  |
| rcp-000321 | fl-original-0155 | Jerk-Spiced Chicken Burgers with Charred Lime | 2 | 348.3 → 481.8 | 33.0 → 37.7 | 697.2 → 922.2 |  |
| rcp-000322 | fl-original-0156 | Island-Spiced Cauliflower with Coconut Rice and Peas | 2 | 568.8 → 568.8 | 9.7 → 9.7 | 1168.1 → 1168.1 | jerk seasoning paste — the paste is a heat/marinade seasoning here and the title ('Island-Spiced') does not name it, per the packet rule; rcp-000321's title does name jerk, so that line is measured instead |
| rcp-000330 | fl-original-0164 | Slow-Simmered Chicken Tagine with Olives and Lemon | 2 | 1192.3 → 1413.3 | 81.3 → 81.3 | 1806.6 → 1807.1 | ras el hanout — a spice blend, per the packet rule |
| rcp-000332 | fl-original-0166 | Squash and Cavolo Nero Stew with Chickpeas | 2 | 1126.0 → 1216.0 | 55.0 → 57.0 | 2097.1 → 2105.1 |  |
| rcp-000333 | fl-original-0167 | Calabrian Nduja and Greens Orecchiette | 2 | 354.9 → 354.9 | 12.7 → 12.7 | 1034.0 → 1034.0 |  |
| rcp-000340 | fl-original-0174 | Sardine and Broccoli Pasta with Toasted Pine Nuts | 2 | 434.6 → 675.9 | 11.5 → 29.0 | 1184.1 → 1394.6 |  |
| rcp-000342 | fl-original-0176 | Quick Sausage and Bean Traybake | 2 | 544.3 → 1031.8 | 18.1 → 45.9 | 1066.4 → 2287.4 |  |
| rcp-000343 | fl-original-0177 | Pomegranate Chicken over Almond Couscous | 2 | 715.3 → 740.2 | 52.7 → 53.2 | 987.3 → 988.2 |  |
| rcp-000344 | fl-original-0178 | Salmon and Prawn Burgers with Chili-Yogurt Sauce | 2 | 557.3 → 690.8 | 47.6 → 52.4 | 1517.8 → 1742.8 |  |
| rcp-000347 | fl-original-0181 | Classic Tuna Nicoise with Lemon Dressing | 2 | 429.8 → 629.9 | 36.0 → 37.4 | 743.3 → 748.2 |  |
| rcp-000349 | fl-original-0183 | Sardine Pomodoro Pasta with Lemony Gremolata | 2 | 406.1 → 530.9 | 8.3 → 23.1 | 1141.1 → 1325.3 |  |
| rcp-000351 | fl-original-0185 | Sausage, Kale and Bean Minestrone | 2 | 714.8 → 1039.8 | 34.6 → 53.2 | 1996.0 → 2810.0 |  |
| rcp-000353 | fl-original-0187 | Sesame Chicken Salad with Crisp Vegetables | 2 | 453.8 → 511.1 | 51.1 → 52.8 | 858.7 → 859.8 |  |
| rcp-000359 | fl-original-0193 | White Bean Traybake with Whipped Ricotta | 2 | 694.6 → 784.6 | 24.4 → 28.9 | 1125.6 → 1191.6 |  |
| rcp-000360 | fl-original-0194 | Apple Cider Bean Stew with Cheddar-Parsley Mash | 2 | 690.5 → 748.0 | 24.7 → 24.8 | 1185.0 → 1190.0 |  |
| rcp-000361 | fl-original-0195 | Jacket Potatoes with Sriracha Tuna Mayo | 2 | 354.6 → 451.1 | 15.8 → 35.6 | 1505.7 → 1754.1 |  |
| rcp-000363 | fl-original-0197 | Squash and Lentil Soup with Smoked Paprika | 2 | 507.2 → 597.2 | 24.5 → 26.5 | 18.4 → 26.4 |  |
| rcp-000364 | fl-original-0198 | Watermelon, Cucumber and Chili Salad | 2 | 149.4 → 209.4 | 3.4 → 4.6 | 1343.1 → 1345.1 | a handful of mint leaves — a finishing herb, per the packet rule |
| rcp-000366 | fl-original-0200 | Root Vegetable and Lentil Casserole with Crumb Top | 2 | 645.4 → 645.4 | 22.8 → 22.8 | 371.1 → 371.1 | rosemary leaves — a seasoning herb, per the packet rule |
| rcp-000368 | fl-original-0202 | Sweet Potato and Red Lentil Dhal with Garlic Spinach | 2 | 638.7 → 638.7 | 26.7 → 26.7 | 253.2 → 253.2 | ground turmeric — a ground spice, per the packet rule |
| rcp-000370 | fl-original-0204 | Spring Tabbouleh with Peas and Lemon | 2 | 404.8 → 419.2 | 10.9 → 12.1 | 13.1 → 35.5 |  |
| rcp-000371 | fl-original-0205 | Cauliflower Tabbouleh with Spring Vegetables | 2 | 236.7 → 243.7 | 7.6 → 8.0 | 53.5 → 56.6 |  |
| rcp-000372 | fl-original-0206 | Sticky Glazed Aubergine with Tomato Salad | 2 | 243.8 → 265.4 | 4.4 → 5.4 | 903.5 → 909.5 |  |
| rcp-000373 | fl-original-0207 | Miso-Honey Aubergine Traybake with Rice | 2 | 348.4 → 348.4 | 9.8 → 9.8 | 1417.6 → 1417.6 | toasted sesame seeds — a garnish and the title names miso and honey, not sesame, per the packet rule |
| rcp-000374 | fl-original-0208 | Weeknight Garden-Veg Spaghetti | 2 | 402.7 → 425.2 | 9.2 → 10.3 | 361.4 → 367.6 |  |
| rcp-000375 | fl-original-0209 | Ginger-Salmon Burgers with Cucumber Slaw | 2 | 404.0 → 537.5 | 35.0 → 39.7 | 789.2 → 1014.2 |  |
| rcp-000376 | fl-original-0210 | Singapore-Style Curry Noodles with Chicken | 2 | 430.4 → 454.8 | 26.8 → 27.9 | 1684.3 → 1688.2 |  |

86 band recipes; 118 unknown non-staple lines at base; every line is either measured or justified above.
