# Build all Direction H screens into ../screens/.
import os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import hkit
from hkit import page, phone, write
import scr_tonight, scr_kitchen, scr_recipe, scr_social, scr_shell

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "screens")

def main():
    os.makedirs(OUT, exist_ok=True)
    for mod in (scr_tonight, scr_kitchen, scr_recipe, scr_social, scr_shell):
        mod.build(write, page, phone)
    files = sorted(os.listdir(OUT))
    print(f"{len(files)} files:")
    for f in files:
        print(" ", f)

if __name__ == "__main__":
    main()
