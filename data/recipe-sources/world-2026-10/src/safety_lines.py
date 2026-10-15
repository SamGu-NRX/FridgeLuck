"""Shared check-sentence constants for the world-2026-10 packet.

Every check step's text names an instant-read thermometer reading of the class
minimum (USDA FSIS Safe Minimum Internal Temperature Chart); the compiler
attaches the matching safety object. Whole-cut classes state the required
3-minute rest in the instruction text.
"""

FSIS_SOURCE = "USDA FSIS Safe Minimum Internal Temperature Chart"

ENDPOINTS = {
    "meat_poultry": 165,
    "meat_ground": 160,
    "egg": 160,
    "flesh_fish": 145,
    "flesh_shellfish": 145,
    "meat_whole_cut_pork": 145,
    "meat_whole_cut_red": 145,
}
REST_MINUTES = {
    "meat_whole_cut_pork": 3,
    "meat_whole_cut_red": 3,
}

CHECK_SENTENCES = {
    "meat_poultry":
        "Cook until an instant-read thermometer reads 165 °F in the thickest piece of chicken.",
    "meat_ground":
        "Cook until an instant-read thermometer reads 160 °F, breaking the meat into crumbles.",
    "egg":
        "Cook until an instant-read thermometer reads 160 °F.",
    "flesh_fish":
        "Cook until an instant-read thermometer reads 145 °F at the thickest point of the fish.",
    "flesh_shellfish":
        "Cook until an instant-read thermometer reads 145 °F.",
    "meat_whole_cut_pork":
        "Cook until an instant-read thermometer reads 145 °F in the center. "
        "Let the pork rest at least 3 minutes before slicing.",
    "meat_whole_cut_red":
        "Cook until an instant-read thermometer reads 145 °F. "
        "Rest the beef at least 3 minutes before slicing.",
}
