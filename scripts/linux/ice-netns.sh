#!/usr/bin/env bash
# 自研 ICE 的真实 NAT 集成测试（第三期实施契约 05 §6.3）。
#
# 用 netns 搭两台 leapgate-server（s1、s2，只用 21116/UDP 的 STUN）、两台 nftables NAT 路由器
# （r1、r2）和三台主机（a、a2 在 r1 后面，b 在 r2 后面），按六组 NAT 组合各跑 3 次 ice_peer：
#   a   ↔ a2  不经 NAT          期望 host/v4 <-> host/v4
#   全锥形   ↔ 全锥形            期望选中，至少一端是 srflx 或 prflx
#   端口受限 ↔ 端口受限          期望选中
#   全锥形   ↔ 对称              期望选中，对称一侧被 a 学成 prflx
#   端口受限 ↔ 对称              期望 no_pair，CHECK_TIMEOUT + 1 秒内结束
#   对称     ↔ 对称              期望 no_pair，同上
# 参数（LeapgateIceParams 的十六进制）由脚本经 fifo 在两个 ice_peer 之间转交，不经 S 的信令。
# 每组重建整套 netns（conntrack 一起清掉）；退出时（含中途失败、Ctrl-C）删掉全部 netns 和后台进程，
# NAT 规则都在 netns 里，随 netns 一起删。不碰根 netns。
#
# 用法：sudo scripts/linux/ice-netns.sh <leapgate-server> <ice_peer>
#   两个路径也可以用环境变量 LEAPGATE_SERVER、ICE_PEER 给。ice_peer 由
#   `cargo build -p leapgate --example ice_peer` 编出（在 leapgate-client 里）。
# 全部通过时退出码 0；有组没通过是 1；自检（NAT 没配对）或环境出错是 2。

set -euo pipefail

SERVER=${1:-${LEAPGATE_SERVER:-}}
PEER=${2:-${ICE_PEER:-}}
if [[ -z $SERVER || -z $PEER ]]; then
    echo "usage: sudo $0 <leapgate-server> <ice_peer>" >&2
    exit 2
fi
SERVER=$(realpath "$SERVER")
PEER=$(realpath "$PEER")
[[ $EUID -eq 0 ]] || { echo "need root" >&2; exit 2; }
[[ -x $SERVER && -x $PEER ]] || { echo "not executable: $SERVER / $PEER" >&2; exit 2; }

P=lgice                     # netns 名字前缀，清理时按它找
STUN1=203.0.113.1:21116
STUN2=203.0.113.2:21116
CHECK_TIMEOUT_MS=3000       # libs/leapgate/src/ice/check.rs
NO_PAIR_LIMIT_MS=$((CHECK_TIMEOUT_MS + 1000))
RUNS=3

WORK=$(mktemp -d /tmp/ice-netns.XXXXXX)
PIDS=()

ns() { local n=$1; shift; ip netns exec "$P-$n" "$@"; }

teardown() {
    local n pid
    for pid in "${PIDS[@]}"; do kill "$pid" 2>/dev/null || true; done
    for n in $(ip netns list | awk '{print $1}' | grep "^$P-" || true); do
        # ip netns del 不杀进程，进程还在时 netns 也不会真正消失
        for pid in $(ip netns pids "$n" 2>/dev/null); do kill -9 "$pid" 2>/dev/null || true; done
        ip netns del "$n" 2>/dev/null || true
    done
    PIDS=()
}

cleanup() {
    local rc=$?
    exec 7>&- 8>&-
    teardown
    rm -rf "$WORK"
    if ip netns list | grep -q "^$P-"; then
        echo "cleanup: netns left behind:" >&2
        ip netns list >&2
        rc=2
    fi
    exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

now_ms() { echo $(( $(date +%s%N) / 1000000 )); }

# ---------- 拓扑 ----------

link() { # <ns 甲> <甲端名> <ns 乙> <乙端名>：在甲里建 veth，另一端直接放进乙，不经过根 netns
    ip -n "$P-$1" link add "$2" type veth peer name "$4" netns "$P-$3"
    ip -n "$P-$1" link set "$2" up
    ip -n "$P-$3" link set "$4" up
}

build_topology() {
    local n
    for n in pub s1 s2 r1 r2 a a2 b; do
        ip netns add "$P-$n"
        ip -n "$P-$n" link set lo up
    done
    ip -n "$P-pub" link add br0 type bridge
    ip -n "$P-pub" link set br0 up
    # 网卡名都带前缀：`ip link add a ...` 里的 a 会被当成 address 的缩写
    for n in s1 s2 r1 r2; do
        link pub "p-$n" "$n" wan
        ip -n "$P-pub" link set "p-$n" master br0
    done
    ip -n "$P-s1" addr add 203.0.113.1/24 dev wan
    ip -n "$P-s2" addr add 203.0.113.2/24 dev wan
    ip -n "$P-r1" addr add 203.0.113.11/24 dev wan
    ip -n "$P-r2" addr add 203.0.113.12/24 dev wan

    # r1 的局域网是网桥，a 和 a2 在同一个二层网段里
    ip -n "$P-r1" link add lan type bridge
    ip -n "$P-r1" link set lan up
    ip -n "$P-r1" addr add 192.168.1.1/24 dev lan
    link r1 l-a a eth0
    link r1 l-a2 a2 eth0
    ip -n "$P-r1" link set l-a master lan
    ip -n "$P-r1" link set l-a2 master lan
    ip -n "$P-a" addr add 192.168.1.10/24 dev eth0
    ip -n "$P-a2" addr add 192.168.1.11/24 dev eth0
    ip -n "$P-a" route add default via 192.168.1.1
    ip -n "$P-a2" route add default via 192.168.1.1

    link r2 l-b b eth0
    ip -n "$P-r2" addr add 192.168.2.1/24 dev l-b
    ip -n "$P-b" addr add 192.168.2.10/24 dev eth0
    ip -n "$P-b" route add default via 192.168.2.1

    ns r1 sysctl -qw net.ipv4.ip_forward=1
    ns r2 sysctl -qw net.ipv4.ip_forward=1

    # 主机不回 ICMP 端口不可达：ice_peer answer 收到第一个 SYN 就退出、关掉 socket，而 offer 选中后
    # 在 connect 过的 socket 上连发 3 个 SYN、发完才打印 selected 行，第二个 SYN 引来的 ICMP 会让
    # send 报 ECONNREFUSED、offer 带着错误退出，结果行就丢了。检查期间两端的 socket 都开着，不受影响。
    for n in a a2 b; do
        ns "$n" nft -f - <<'EOF'
table ip lgice {
    chain output {
        type filter hook output priority filter; policy accept;
        icmp type destination-unreachable icmp code port-unreachable drop
    }
}
EOF
    done
}

# NAT 类型照 §6.3：
#   full     一对一：内网主机 snat 成 wan 地址（端口不冲突时 conntrack 保留源端口），到 wan 地址的 UDP 全部 dnat 回它
#   restrict masquerade；wan 口新建的入站一律丢弃，只放行已有 conntrack 的回包
#   sym      masquerade fully-random（每个新的五元组随机取端口）
# 丢弃要放在 filter 钩子上：没被确认的 conntrack 条目随包一起丢掉，不会占住映射端口；
# 不丢的话，对端先到的检查会在路由器上留下一条 conntrack，之后内网主机发往同一对端时 masquerade
# 为避开它会换端口，映射就不再和对端无关了。
nat_rules() { # <r1|r2> <full|restrict|sym>
    local r=$1 type=$2 wan host
    if [[ $r == r1 ]]; then wan=203.0.113.11 host=192.168.1.10; else wan=203.0.113.12 host=192.168.2.10; fi
    case $type in
        full)
            ns "$r" nft -f - <<EOF
table ip lgice {
    chain pre {
        type nat hook prerouting priority dstnat; policy accept;
        iifname "wan" ip daddr $wan meta l4proto udp dnat to $host
    }
    chain post {
        type nat hook postrouting priority srcnat; policy accept;
        oifname "wan" ip saddr $host snat to $wan
        oifname "wan" masquerade
    }
}
EOF
            ;;
        restrict | sym)
            local masq=masquerade
            [[ $type == sym ]] && masq="masquerade fully-random"
            ns "$r" nft -f - <<EOF
table ip lgice {
    chain post {
        type nat hook postrouting priority srcnat; policy accept;
        oifname "wan" $masq
    }
    chain input {
        type filter hook input priority filter; policy accept;
        iifname "wan" ct state new drop
    }
    chain forward {
        type filter hook forward priority filter; policy accept;
        iifname "wan" ct state new drop
    }
}
EOF
            ;;
    esac
}

start_servers() {
    local s
    for s in s1 s2; do
        mkdir -p "$WORK/$s"
        # 不让它在后台去下载 GeoIP 库（netns 里没有外网，只会白白重试）
        printf '[geo]\nauto_update = false\n' > "$WORK/$s/leapgate.toml"
        (cd "$WORK/$s" && exec ip netns exec "$P-$s" "$SERVER") > "$WORK/$s/server.log" 2>&1 &
        PIDS+=($!)
    done
    for s in s1 s2; do
        local i
        for i in $(seq 100); do
            ns "$s" ss -Hlun 'sport = :21116' | grep -q . && break
            sleep 0.2
        done
        if ! ns "$s" ss -Hlun 'sport = :21116' | grep -q .; then
            echo "leapgate-server in $s did not bind 21116/udp:" >&2
            tail -n 20 "$WORK/$s/server.log" >&2
            exit 2
        fi
    done
}

# ---------- 自检 ----------

# 向 s1、s2 各问一次（同一个 socket），映射相同 = 端点无关映射（全锥形或端口受限），不同 = 对称
selftest() { # <host ns> <ip> <full|restrict|sym|none> <router>
    local h=$1 ip=$2 type=$3 r=$4 out m1 m2
    out=$(ns "$h" "$PEER" --probe "$ip" "$STUN1" "$STUN2")
    m1=$(sed -n 1p <<<"$out" | awk '{print $2}')
    m2=$(sed -n 2p <<<"$out" | awk '{print $2}')
    echo "  selftest $h ($type): s1 sees $m1, s2 sees $m2"
    if [[ -z $m1 || -z $m2 || $m1 == none || $m2 == none ]]; then
        echo "  NAT not set up right: $h got no mapping" >&2
        exit 2
    fi
    case $type in
        sym) [[ $m1 != "$m2" ]] || { echo "  NAT not set up right: $h expects symmetric, mapping is the same" >&2; exit 2; } ;;
        *) [[ $m1 == "$m2" ]] || { echo "  NAT not set up right: $h expects endpoint-independent mapping, got two" >&2; exit 2; } ;;
    esac
    # 映射自检分不出全锥形和端口受限，全锥形另外确认 dnat 规则在
    if [[ $type == full ]]; then
        local rule
        rule=$(ns "$r" nft list ruleset | grep -E 'dnat (ip )?to' | sed 's/^[[:space:]]*//')
        [[ -n $rule ]] || { echo "  NAT not set up right: no dnat rule in $r" >&2; exit 2; }
        echo "  selftest $r: $rule"
    fi
}

# ---------- 一次检查 ----------

wait_line() { # <file> <prefix> <pid> <timeout ms>：等文件里出现以 prefix 开头的一行
    local f=$1 pfx=$2 pid=$3 deadline=$(( $(now_ms) + $4 ))
    while (( $(now_ms) < deadline )); do
        grep -m1 "^$pfx" "$f" 2>/dev/null && return 0
        kill -0 "$pid" 2>/dev/null || { grep -m1 "^$pfx" "$f" 2>/dev/null; return $?; }
        sleep 0.02
    done
    return 1
}

wait_exit() { # <pid> <timeout ms>：返回进程退出码；超时杀掉、返回 124
    local pid=$1 deadline=$(( $(now_ms) + $2 ))
    while kill -0 "$pid" 2>/dev/null; do
        if (( $(now_ms) >= deadline )); then
            kill -9 "$pid" 2>/dev/null || true
            wait "$pid" 2>/dev/null || true
            return 124
        fi
        sleep 0.01
    done
    local rc=0
    wait "$pid" || rc=$?
    return "$rc"
}

# 结果写进全局变量 R_A（a 的结果行）、R_B、R_RC_A、R_RC_B、R_MS（交出 b 的参数到 a 退出的毫秒数）
run_once() { # <a ns> <a ip> <b ns> <b ip> <tag>
    local an=$1 aip=$2 bn=$3 bip=$4 d="$WORK/$5" pa pb la lb t0
    mkdir -p "$d"
    mkfifo "$d/a.in" "$d/b.in"
    # 不经 ns()：后台跑函数会多一层子 shell，$! 就不是 ice_peer 本身了
    ip netns exec "$P-$an" "$PEER" offer "$aip" "$STUN1" < "$d/a.in" > "$d/a.out" 2> "$d/a.err" &
    pa=$!
    ip netns exec "$P-$bn" "$PEER" answer "$bip" "$STUN1" < "$d/b.in" > "$d/b.out" 2> "$d/b.err" &
    pb=$!
    PIDS+=("$pa" "$pb")
    # 写端一直开着：ice_peer 只读一行，但 stdin 提前 EOF 会让它读到空行
    exec 7> "$d/a.in" 8> "$d/b.in"

    R_A="" R_B="" R_RC_A="" R_RC_B="" R_MS=""
    if la=$(wait_line "$d/a.out" "params " "$pa" 5000); then
        printf '%s\n' "$la" >&8
        if lb=$(wait_line "$d/b.out" "params " "$pb" 5000); then
            t0=$(now_ms)
            printf '%s\n' "$lb" >&7
        fi
    fi
    if [[ -z ${t0:-} ]]; then
        echo "    params exchange failed; a: $(cat "$d/a.err") b: $(cat "$d/b.err")" >&2
        t0=$(now_ms)
    fi
    R_RC_A=0; wait_exit "$pa" 15000 || R_RC_A=$?
    R_MS=$(( $(now_ms) - t0 ))
    R_RC_B=0; wait_exit "$pb" 15000 || R_RC_B=$?
    exec 7>&- 8>&-
    R_A=$(grep -E '^(selected|no_pair)' "$d/a.out" | head -n 1 || true)
    R_B=$(grep -E '^(accepted|timed_out)' "$d/b.out" | head -n 1 || true)
    [[ -s $d/a.err ]] && echo "    a stderr: $(head -c 300 "$d/a.err")"
    [[ -s $d/b.err ]] && echo "    b stderr: $(head -c 300 "$d/b.err")"
    return 0
}

# ---------- 判定 ----------

judge() { # <expect>：按 R_* 判一次，返回 0 通过
    local expect=$1 local_kind remote_kind
    [[ $R_RC_A == 0 && $R_RC_B == 0 ]] || return 1
    if [[ $expect == no_pair ]]; then
        [[ $R_A == no_pair ]] && (( R_MS <= NO_PAIR_LIMIT_MS ))
        return
    fi
    [[ $R_A == selected* && $R_B == accepted ]] || return 1
    local_kind=$(awk '{print $2}' <<<"$R_A")
    remote_kind=$(awk '{print $4}' <<<"$R_A")
    case $expect in
        host) [[ $local_kind == host/v4 && $remote_kind == host/v4 ]] ;;
        reflexive) [[ $local_kind != host/* || $remote_kind != host/* ]] ;;
        b_prflx) [[ $remote_kind == prflx/* ]] ;;
        any) true ;;
    esac
}

declare -a SUMMARY=()
FAILED=0

group() { # <名字> <r1 类型> <r2 类型> <b 的 ns> <b 的 ip> <期望>
    local name=$1 t1=$2 t2=$3 bn=$4 bip=$5 expect=$6 i ok=0
    echo "== $name (r1 $t1, r2 $t2; a 192.168.1.10 <-> $bn $bip; expect $expect)"
    build_topology
    nat_rules r1 "$t1"
    nat_rules r2 "$t2"
    start_servers
    selftest a 192.168.1.10 "$t1" r1
    if [[ $bn == b ]]; then selftest b "$bip" "$t2" r2; else selftest a2 "$bip" "$t1" r1; fi
    for i in $(seq "$RUNS"); do
        run_once a 192.168.1.10 "$bn" "$bip" "$name-$i"
        local verdict=FAIL
        if judge "$expect"; then verdict=ok; ok=$((ok + 1)); fi
        echo "  run $i: a: ${R_A:-<none>} (exit $R_RC_A, ${R_MS} ms after b's params) | b: ${R_B:-<none>} (exit $R_RC_B) | $verdict"
    done
    local pass=PASS
    if (( ok != RUNS )); then pass=FAIL; FAILED=1; fi
    SUMMARY+=("$(printf '%-22s %-9s %d/%d %s' "$name" "$expect" "$ok" "$RUNS" "$pass")")
    teardown
}

echo "leapgate-server: $SERVER ($(sha256sum "$SERVER" | cut -c1-16))"
echo "ice_peer:        $PEER ($(sha256sum "$PEER" | cut -c1-16))"
echo "kernel $(uname -r), $(nft --version)"
teardown
started=$(now_ms)

# 期望：host = host/v4 <-> host/v4；reflexive = 至少一端不是 host；b_prflx = a 把 b 学成 prflx；
# any = 选中即可；no_pair = CHECK_TIMEOUT + 1 秒内 no_pair
group lan-a-a2           restrict restrict a2 192.168.1.11 host
group full-full          full     full     b  192.168.2.10 reflexive
group restrict-restrict  restrict restrict b  192.168.2.10 any
group full-sym           full     sym      b  192.168.2.10 b_prflx
group restrict-sym       restrict sym      b  192.168.2.10 no_pair
group sym-sym            sym      sym      b  192.168.2.10 no_pair

echo "== summary ($(( ($(now_ms) - started) / 1000 )) s)"
printf '%s\n' "${SUMMARY[@]}"
exit "$FAILED"
