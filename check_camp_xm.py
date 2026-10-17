# -*- coding: utf-8 -*-
"""check_camp_xm.py — SniperCAMP Tweak.xm 静态深检（无本地 theos，编译前人工+机器双重检查）"""
import re, sys

P = r"D:\sniper_chams\DEB分类\主线+特别行动\Tweak.xm"
src = open(P, encoding="utf-8").read()
errs, warns = [], []

# ---------- 1. 去注释/去字符串后配平 ----------
def strip_code(s):
    out, i, n = [], 0, len(s)
    while i < n:
        c = s[i]
        if c == '"':
            i += 1
            while i < n and s[i] != '"':
                i += 2 if s[i] == '\\' else 1
            i += 1
            out.append('""')
        elif c == "'":
            i += 1
            while i < n and s[i] != "'":
                i += 2 if s[i] == '\\' else 1
            i += 1
            out.append("''")
        elif s.startswith('//', i):
            while i < n and s[i] != '\n': i += 1
        elif s.startswith('/*', i):
            j = s.find('*/', i + 2)
            i = n if j < 0 else j + 2
        else:
            out.append(c); i += 1
    return ''.join(out)

code = strip_code(src)
for op, cl, name in [('{','}','花括号'), ('(',')','圆括号'), ('[',']','方括号')]:
    if code.count(op) != code.count(cl):
        errs.append(f"{name}不配平: {op}={code.count(op)}  {cl}={code.count(cl)}")

# ---------- 2. 代码区（非注释/字符串）不允许非 ASCII ----------
for ln, line in enumerate(code.splitlines(), 1):
    if any(ord(ch) > 127 for ch in line):
        errs.append(f"第{ln}行代码区含非ASCII（中文必须只在注释/字符串里）: {line.strip()[:60]}")

# ---------- 3. 必备结构齐全（字符串类内容查【原始源码】，代码结构查剥后代码） ----------
musts_raw = [
    ('"com.fungames.sniper3d"', 'bundle 常量'),
    ('get_IsUpgradeRequired', '钩1 方法名'),
    ('get_IsUpgradeRecommended', '钩2 方法名'),
    ('get_DisableBallistics', '钩3 方法名'),
    ('camp_config', '配置名'),
    ('camp_tweak.log', '日志名'),
]
musts_code = [
    ('%ctor', '%ctor 入口'),
    ('MSHookFunction(*(void **)m, (void *)my_req, (void **)&orig_req)', '钩1 MSHook(进任务弹窗)'),
    ('MSHookFunction(*(void **)m, (void *)my_rec, (void **)&orig_rec)', '钩2 MSHook(进任务弹窗)'),
    ('MSHookFunction(*(void **)m, (void *)my_shoot, (void **)&orig_shoot)', '钩3 MSHook(Shoot 无限弹/无冷却)'),
    ('static int patchU32(uintptr_t addr, uint32_t val)', '字节补丁写函数(v0.5.3)'),
    ('vm_protect(mach_task_self()', '代码页可写(v0.5.3)'),
    ('sys_icache_invalidate', '指令缓存刷新(v0.5.3)'),
    ('static void updatePatches(void)', '补丁切换(v0.5.3)'),
    ('il2cpp_class_get_method_from_name', '方法解析 API'),
    ('il2cpp_thread_attach', '线程挂载'),
    ('MAX_ATTEMPTS', '重试上限'),
]
for pat, desc in musts_raw:
    if pat not in src:
        errs.append(f"缺必备结构: {desc}  ← 原码未找到「{pat}」")
for pat, desc in musts_code:
    if pat.replace('  ', ' ') not in code.replace('  ', ' '):
        errs.append(f"缺必备结构: {desc}  ← 未找到「{pat}」")

# ---------- 4. TLog 格式串 vs 实参（用【原始源码】保字符串完整） ----------
def split_args(s):
    args, depth, cur, i = [], 0, '', 0
    while i < len(s):
        c = s[i]
        if c == '(': depth += 1
        elif c == ')':
            depth -= 1
            if depth == 0 and cur.strip(): args.append(cur.strip()); break
        elif c == ',' and depth == 1:
            args.append(cur.strip()); cur = ''; i += 1; continue
        cur += c; i += 1
    return args

for m in re.finditer(r'TLog\(', src):
    start = m.end() - 1
    args = split_args(src[start:])
    if not args: continue
    args[0] = args[0].lstrip('( \t')   # split_args 从 '(' 起步，剥掉前导括号
    fmt_m = re.match(r'@"((?:[^"\\]|\\.)*)"', args[0])
    if not fmt_m:
        a0 = args[0]
        if '(NSString' in a0 or a0.startswith('fmt'):
            continue   # TLog 自身声明/定义
        warns.append(f"TLog 格式串不是字面量（跳过）: {a0[:40]}"); continue
    fmt = fmt_m.group(1)
    nspec = 0
    i = 0
    while i < len(fmt):
        if fmt[i] == '%':
            if i + 1 < len(fmt) and fmt[i+1] == '%':
                i += 2; continue
            nspec += 1
            conv = re.match(r'%[-+ #0]*[\*0-9]*(h|hh|l|ll|q|z|t|L)?([diouxXeEfgGcsp%@aAn])', fmt[i:])
            if not conv:
                errs.append(f"TLog 格式串含未知转换: …{fmt[i:i+8]}…"); break
            i += conv.end() - 1
        i += 1
    nargs = len(args) - 1
    if nspec != nargs:
        errs.append(f"TLog 参数数不匹配: 「{fmt[:50]}」 需 {nspec} 实参给了 {nargs}")

# ---------- 5. 每个被调用函数都有定义（static 函数集合） ----------
defs = set(re.findall(r'static\s+[\w\s\*]+?\b(\w+)\s*\(', code))
for fn in ['TLog','LoadConfig','WriteDefaultConfig','JsonBool','my_req','my_rec','my_shoot',
           'patchU32','updatePatches','bindIl2cpp','collectImages','findMethodInfo','installHooks','startTimers',
           'setupStep','scheduleRetry']:
    if fn not in defs:
        errs.append(f"函数疑似未定义: {fn}")
    if re.search(r'\b' + fn + r'\s*\(', code) is None:
        errs.append(f"函数疑似未被引用: {fn}")

# ---------- 6. 替换体/补丁切换必须先判 cfg.master ----------
for fn in ['my_req', 'my_rec']:
    body = re.search(r'static BOOL ' + fn + r'\(void \*self\) \{(.*?)\n\}', code, re.S)
    if not body:
        errs.append(f"{fn} 函数体没抓到"); continue
    b = body.group(1)
    if 'cfg.master' not in b:
        errs.append(f"{fn} 没有判 cfg.master（热开关失效）")
    if 'return NO' not in b:
        errs.append(f'{fn} 关闸分支必须 return NO')
# my_shoot：补弹/免冷却分支必须判 cfg.master
msh = re.search(r'static void my_shoot\(void \*self\) \{(.*?)\n\}', code, re.S)
if not msh:
    errs.append('my_shoot 函数体没抓到')
elif 'cfg.master' not in msh.group(1):
    errs.append('my_shoot 没有判 cfg.master（master=0 仍在补弹/免冷却）')
# updatePatches：字节补丁必须 gate cfg.master（v0.5.3 弹道/扳机两颗）
up = re.search(r'static void updatePatches\(void\) \{(.*?)\n\}', code, re.S)
if not up:
    errs.append('updatePatches 函数体没抓到')
elif 'cfg.master' not in up.group(1):
    errs.append('updatePatches 没有判 cfg.master（master=0 补丁仍生效）')

# ---------- 7. 计数器/日志类型抽查 ----------
if not re.search(r'long nReqBlocked\s*=\s*0,\s*nRecBlocked\s*=\s*0,\s*nShootRefill\s*=\s*0', code):
    errs.append('计数器定义不是 long 三连（req/rec/refill；v0.5.3 起无 nBalForced）')

# ---------- 输出 ----------
print(f"文件: {P}  ({len(src)} 字节, {src.count(chr(10))+1} 行)")
print('=' * 60)
for w in warns: print('[WARN]', w)
if errs:
    for e in errs: print('[❌]', e)
    print(f'\n结论: ❌ {len(errs)} 个错误，必须修')
    sys.exit(1)
print('结论: ✅ 静态检查全部通过（配平/格式串/结构/替换体语义）')
