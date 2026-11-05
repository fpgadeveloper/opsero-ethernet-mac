#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
#
# simlib.py - helpers shared by the opsero-ethernet-mac testbench drivers: the RTL
# file lists (ip/<ip>/rtl/<ip>.f) and an xsim runner (compile once per build
# directory and configuration, re-compile when a source changes, then run with
# plusargs). Needs Vivado's xvlog / xelab / xsim on PATH, or VIVADO_SETTINGS
# pointing at Vivado's settings64.sh (a few usual install locations are tried).
#
# Copyright (c) 2026 Opsero Electronic Design Inc.

import glob
import hashlib
import os
import shutil
import subprocess

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
BUILD = os.environ.get('SIM_BUILD', os.path.join(HERE, 'build'))


def ip_files(ip):
    """The source list of an IP (ip/<ip>/rtl/<ip>.f), absolute paths, in compile order."""
    out = []
    with open(os.path.join(ROOT, 'ip', ip, 'rtl', ip + '.f')) as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith('#'):
                out.append(os.path.join(ROOT, line))
    return out


def common(*names):
    """common/<name> files, with the package first."""
    return [os.path.join(ROOT, 'common', 'omac_pkg.sv')] + [os.path.join(ROOT, 'common', n) for n in names]


_env = None


def _tool_env():
    global _env
    if _env is not None:
        return _env
    env = dict(os.environ)
    if shutil.which('xvlog') is None:
        cands = [os.environ.get('VIVADO_SETTINGS', '')]
        cands += sorted(glob.glob('/tools/Xilinx/*/Vivado/settings64.sh'), reverse=True)
        cands += sorted(glob.glob(os.path.expanduser('~/Xilinx/*/Vivado/settings64.sh')), reverse=True)
        cands += sorted(glob.glob('/opt/Xilinx/*/Vivado/settings64.sh'), reverse=True)
        cands += sorted(glob.glob('/tools/Xilinx/Vivado/*/settings64.sh'), reverse=True)
        for c in cands:
            if c and os.path.exists(c):
                out = subprocess.run(['bash', '-c', 'source "%s" >/dev/null 2>&1; env -0' % c],
                                     capture_output=True, text=True).stdout
                env = dict(kv.split('=', 1) for kv in out.split('\0') if '=' in kv)
                break
        else:
            raise RuntimeError('Vivado xsim not found: put xvlog on PATH or set VIVADO_SETTINGS')
    _env = env
    return env


def xsim(build_dir, top, generics, srcs, plusargs=(), timeout=3600, seed=None, incdirs=(HERE,)):
    """Compile (once per configuration) and run a testbench; returns (filtered output, full log).
    The filtered output keeps the TB_* lines and every error / fatal line."""
    env = _tool_env()
    os.makedirs(build_dir, exist_ok=True)
    key = '%s %s %s' % (top, sorted(generics.items()), srcs)
    stamp = hashlib.md5(key.encode()).hexdigest()[:10]
    snap = 'snap_' + stamp
    marker = os.path.join(build_dir, 'built.' + stamp)
    newest = max(os.path.getmtime(f) for f in srcs)
    if not os.path.exists(marker) or os.path.getmtime(marker) < newest:
        cmd = ['xvlog', '--sv'] + sum([['-i', i] for i in incdirs], []) + list(srcs)
        r = subprocess.run(cmd, cwd=build_dir, env=env, capture_output=True, text=True)
        if r.returncode != 0:
            errs = [l for l in r.stdout.splitlines() if 'ERROR' in l]
            return 'COMPILE_ERROR\n' + '\n'.join(errs[:30]), r.stdout
        gargs = []
        for k, v in generics.items():
            if isinstance(v, str):
                gargs += ['-generic_top', '%s=%s' % (k, v)]
            else:
                gargs += ['-generic_top', '%s=%d' % (k, v)]
        cmd = ['xelab', '-debug', 'off', '--timescale', '1ns/1ps'] + gargs + [top, '-s', snap]
        r = subprocess.run(cmd, cwd=build_dir, env=env, capture_output=True, text=True)
        if r.returncode != 0:
            errs = [l for l in r.stdout.splitlines() if 'ERROR' in l]
            return 'ELAB_ERROR\n' + '\n'.join(errs[:30]), r.stdout
        open(marker, 'w').close()
    cmd = ['xsim', snap, '-R'] + sum([['-testplusarg', a] for a in plusargs], [])
    if seed is not None:
        cmd += ['-sv_seed', str(seed)]
    try:
        r = subprocess.run(cmd, cwd=build_dir, env=env, capture_output=True, text=True, timeout=timeout)
        log = r.stdout
    except subprocess.TimeoutExpired as e:
        log = (e.stdout or b'').decode() if isinstance(e.stdout, bytes) else (e.stdout or '')
        log += '\nTB_TIMEOUT (wall clock)'
    keep = [l for l in log.splitlines() if l.startswith('TB_') or 'ERROR' in l or
            'FATAL' in l or 'Fatal' in l]
    return '\n'.join(keep[:60]), log


def tb_values(out, tag):
    """Parse 'TB_<tag> k=v k=v ...' lines into a list of dicts (ints where possible)."""
    res = []
    for l in out.splitlines():
        if l.startswith('TB_' + tag + ' ') or l == 'TB_' + tag:
            d = {}
            for kv in l.split()[1:]:
                if '=' in kv:
                    k, v = kv.split('=', 1)
                    try:
                        d[k] = int(v, 0)
                    except ValueError:
                        d[k] = v
            res.append(d)
    return res
