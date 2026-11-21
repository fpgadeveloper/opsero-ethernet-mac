#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
#
# test_omac_mdio_drv.py - compiles and runs the host unit test of the omac_mdio
# bare-metal driver (test_omac_mdio_drv.c, which includes ../omac_mdio.c) with the host C compiler
# ($CC, else cc), warnings as errors. Build products: sim/build/omac_mdio_drv.
#
# Copyright (c) 2026 Opsero Electronic Design Inc.

import os
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
DRV = os.path.dirname(HERE)
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(DRV))))
BUILD = os.path.join(os.environ.get('SIM_BUILD', os.path.join(ROOT, 'sim', 'build')), 'omac_mdio_drv')


def main():
    cc = os.environ.get('CC') or shutil.which('cc') or shutil.which('gcc')
    if not cc:
        print('no C compiler (set CC)')
        print('OMAC_MDIO_DRV TEST FAIL')
        return 1
    os.makedirs(BUILD, exist_ok=True)
    exe = os.path.join(BUILD, 'test_omac_mdio_drv')
    cmd = [cc, '-std=c99', '-O2', '-Wall', '-Wextra', '-Wpedantic', '-Werror', '-I', DRV, '-o', exe,
           os.path.join(HERE, 'test_omac_mdio_drv.c')]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        print(r.stdout + r.stderr)
        print('OMAC_MDIO_DRV TEST FAIL (compile)')
        return 1
    r = subprocess.run([exe], capture_output=True, text=True)
    print(r.stdout.strip())
    return r.returncode


if __name__ == '__main__':
    sys.exit(main())
