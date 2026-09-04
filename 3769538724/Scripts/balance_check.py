import re, sys

def strip_comments_and_strings(line):
    """粗粒度剥离：行注释 --、块注释 --[[ ]](假设单行内闭合)、双引号字符串、单引号字符串、长字符串"""
    out = []
    i = 0
    n = len(line)
    while i < n:
        c = line[i]
        nxt = line[i+1] if i+1 < n else ''
        if c == '-' and nxt == '-':
            # 检查是否为 [[ 块注释
            if line[i+2:i+4] == '[[':
                j = line.find(']]', i+4)
                if j == -1:
                    break
                i = j + 2
                continue
            break
        if c == '"':
            j = i + 1
            while j < n:
                if line[j] == '\\':
                    j += 2
                    continue
                if line[j] == '"':
                    break
                j += 1
            i = j + 1
            continue
        if c == "'":
            j = i + 1
            while j < n:
                if line[j] == '\\':
                    j += 2
                    continue
                if line[j] == "'":
                    break
                j += 1
            i = j + 1
            continue
        out.append(c)
        i += 1
    return ''.join(out)

def tokens_of(line):
    return re.findall(r'\b(if|elseif|else|end|for|while|do|function|then)\b', line)

OPENERS = {'if', 'for', 'while', 'do', 'function'}
# elseif 不算 opener（不新增匹配的 end），then/else 无结构性影响

def signature(path):
    depth = 0
    sig = []
    min_d = 0
    for lineno, raw in enumerate(open(path, encoding='utf-8'), 1):
        line = strip_comments_and_strings(raw)
        toks = tokens_of(line)
        for t in toks:
            if t in OPENERS:
                depth += 1
            elif t == 'end':
                depth -= 1
            sig.append((lineno, t, depth))
            min_d = min(min_d, depth)
    return depth, min_d, sig

def final_depths(path):
    d, m, _ = signature(path)
    return d, m

def report(path):
    d, m, sig = signature(path)
    neg = [s for s in sig if s[2] < 0]
    return d, m, len(neg)

if __name__ == '__main__':
    for p in sys.argv[1:]:
        d, m, neg = report(p)
        print(f"{p}: final_depth={d} min_depth={m} negative_dips={neg}")
