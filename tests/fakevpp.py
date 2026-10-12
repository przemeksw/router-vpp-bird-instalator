#!/usr/bin/env python3
"""Symulator vppctl / ip (netns) do testów router-ifaces. Stan w $FAKEVPP_STATE (JSON)."""
import ipaddress
import json
import os
import re
import sys

SF = os.environ["FAKEVPP_STATE"]


def load():
    try:
        with open(SF) as f:
            return json.load(f)
    except (OSError, ValueError):
        st = {"if": {}, "lcp": {}, "linux": {}, "next": 1, "auto_subint": True}
        for n in ("local0", "hu0", "hu1"):
            st["if"][n] = {"idx": len(st["if"]), "up": n == "hu0", "mtu": 9000 if n != "local0" else 0, "addrs": []}
        return st


def save(st):
    with open(SF, "w") as f:
        json.dump(st, f)


def add_if(st, name, mtu=9000):
    st["if"][name] = {"idx": max(i["idx"] for i in st["if"].values()) + 1, "up": False, "mtu": mtu, "addrs": []}


def add_lcp(st, name, host):
    st["lcp"][name] = host
    st["linux"][host] = st["linux"].get(host, "")
    # jak prawdziwy kernel bez addr_gen_mode=none: Linux nadaje link-local, linux-cp przenosi go do VPP (IPv6 włączone)
    ll = st.get("ll_default", True)
    st.setdefault("ll", {})[host] = ll
    if ll:
        st["if"][name]["ip6"] = True
    st.setdefault("laddr", {})[host] = list(st["if"][name]["addrs"]) if st.get("lcp_sync", True) else []


def sync_addr(st, name, a, add):
    if not st.get("lcp_sync", True) or name not in st["lcp"]:
        return
    lst = st.setdefault("laddr", {}).setdefault(st["lcp"][name], [])
    if add and a not in lst:
        lst.append(a)
    if not add and a in lst:
        lst.remove(a)


def vppctl(cmd):
    st = load()
    t = cmd.split()
    out = ""
    try:
        if cmd == "show version":
            out = "vpp v26.06-fake"
        elif cmd == "show interface":
            out = "              Name               Idx    State  MTU (L3/IP4/IP6/MPLS)     Counter          Count     \n"
            for n, i in sorted(st["if"].items(), key=lambda x: x[1]["idx"]):
                out += "%-33s %-6d %-5s %10s\n" % (n, i["idx"], "up" if i["up"] else "down", "%d/0/0/0" % i["mtu"])
                if i["up"]:
                    out += "%70s rx packets   123\n" % ""
            for n, h in st["lcp"].items():
                pass
        elif cmd == "show interface address":
            for n, i in sorted(st["if"].items(), key=lambda x: x[1]["idx"]):
                out += "%s (%s):\n" % (n, "up" if i["up"] else "dn")
                for a in i["addrs"]:
                    out += "  L3 %s\n" % a
        elif t[:2] == ["fake", "ll-default"]:   # tylko testy: netns z addr_gen_mode=1 (nowe interfejsy bez link-local)
            st["ll_default"] = t[2] == "on"
        elif cmd == "show ip6 interface":
            for n, i in sorted(st["if"].items(), key=lambda x: x[1]["idx"]):
                if i.get("ip6") or any(":" in a for a in i["addrs"]):
                    out += "%s is admin %s\n  Link-local address(es):\n    fe80::1/64\n" % (n, "up" if i["up"] else "down")
        elif t[:3] in (["enable", "ip6", "interface"], ["disable", "ip6", "interface"]):
            if t[3] not in st["if"]:
                raise ValueError("unknown interface")
            i = st["if"][t[3]]
            if t[0] == "disable" and not i.get("ip6") and not any(":" in a for a in i["addrs"]):
                raise ValueError("Failed")
            i["ip6"] = t[0] == "enable"
        elif t[:2] == ["ip6", "nd"]:
            if t[2] not in st["if"]:
                raise ValueError("unknown input `%s'" % t[2])
            if t[3:] != ["ra-suppress"]:
                raise ValueError("unknown input `%s'" % " ".join(t[3:]))
            st["if"][t[2]]["ra_suppress"] = True
        elif cmd == "show lcp":
            out = "lcp default netns dataplane\nlcp lcp-auto-subint on\nlcp lcp-sync on\n"
            for k, (n, h) in enumerate(st["lcp"].items()):
                out += "itf-pair: [%d] %s tap%d %s %d type tap netns dataplane\n" % (k, n, 4096 + k, h, 40 + k)
        elif t[:2] == ["create", "sub-interfaces"]:
            p, v = t[2], int(t[3])
            assert t[4:7] == ["dot1q", t[3], "exact-match"]
            if p not in st["if"]:
                raise ValueError("unknown input `%s'" % p)
            n = "%s.%d" % (p, v)
            if n in st["if"]:
                raise ValueError("vlan is already in use")
            add_if(st, n, st["if"][p]["mtu"])
            if st["auto_subint"] and p in st["lcp"]:
                add_lcp(st, n, "%s.%d" % (st["lcp"][p], v))
            out = n
        elif t[:4] == ["create", "loopback", "interface", "instance"]:
            n = "loop" + t[4]
            if n in st["if"]:
                raise ValueError("instance already in use")
            add_if(st, n)
            out = n
        elif t[:3] == ["set", "interface", "state"]:
            if t[3] not in st["if"]:
                raise ValueError("unknown input `%s'" % t[3])
            st["if"][t[3]]["up"] = t[4] == "up"
        elif t[:3] == ["set", "interface", "mtu"]:
            if t[3] == "packet":
                st["if"][t[5]]["mtu"] = int(t[4])
            else:
                st["if"][t[4]]["mtu"] = int(t[3])
        elif t[:4] == ["set", "interface", "ip", "address"]:
            dl = t[4] == "del"
            n, a = (t[5], t[6]) if dl else (t[4], t[5])
            if n not in st["if"]:
                raise ValueError("unknown input `%s'" % n)
            ia = ipaddress.ip_interface(a)
            if dl:
                if a not in st["if"][n]["addrs"]:
                    raise ValueError("address not found")
                st["if"][n]["addrs"].remove(a)
                sync_addr(st, n, a, False)
            else:
                for n2, i2 in st["if"].items():
                    for a2 in i2["addrs"]:
                        b = ipaddress.ip_interface(a2)
                        if b.version == ia.version and n2 != n and b.network.overlaps(ia.network):
                            raise ValueError("set interface ip address: failed to add %s on %s which conflicts "
                                             "with %s for interface %s" % (a, n, a2, n2))
                if a not in st["if"][n]["addrs"]:
                    st["if"][n]["addrs"].append(a)
                    sync_addr(st, n, a, True)
        elif t[:2] == ["lcp", "create"]:
            n, h = t[2], t[4]
            if n not in st["if"]:
                raise ValueError("unknown input `%s'" % n)
            if n in st["lcp"]:
                raise ValueError("lcp create: interface already has a pair")
            if "." in n and n.split(".")[0] not in st["lcp"]:
                raise ValueError("lcp create: parent has no LIP")
            add_lcp(st, n, h)
        elif t[:2] == ["lcp", "delete"]:
            h = st["lcp"].pop(t[2])
            st["linux"].pop(h, None)
            st.get("laddr", {}).pop(h, None)
        elif t[:2] == ["delete", "sub-interface"]:
            n = t[2]
            if n in st["lcp"]:
                st["linux"].pop(st["lcp"].pop(n), None)
            del st["if"][n]
        elif t[:4] == ["delete", "loopback", "interface", "intfc"]:
            del st["if"][t[4]]
        elif t[:3] == ["set", "acl-plugin", "acl"]:
            body, idx = cmd[len("set acl-plugin acl"):].strip(), None
            m = re.match(r"index (\d+)\s+(.*)$", body)
            if m:
                idx, body = int(m.group(1)), m.group(2)
            m = re.match(r"(.*)\s+tag (\S+)$", body)
            if not m:
                raise ValueError("unknown input `%s'" % body)
            rules, tag = [r.strip() for r in m.group(1).split(",")], m.group(2)
            for r in rules:
                if not re.fullmatch(r"(permit|deny|permit\+reflect) src \S+ dst \S+( proto \d+)?"
                                    r"( sport \d+(-\d+)?)?( dport \d+(-\d+)?)?", r):
                    raise ValueError("unknown input `%s'" % r)
            acl = st.setdefault("acl", {})
            if idx is None:
                idx = st.get("acl_next", 0)
                st["acl_next"] = idx + 1
                out = "ACL index:%d" % idx
            elif str(idx) not in acl:
                raise ValueError("ACL index %d not found" % idx)
            acl[str(idx)] = {"rules": rules, "tag": tag}
        elif t[:4] == ["delete", "acl-plugin", "acl", "index"]:
            acl = st.setdefault("acl", {})
            if t[4] not in acl:
                raise ValueError("ACL not found")
            if any(int(t[4]) in lst for b in st.get("aclbind", {}).values() for lst in b.values()):
                raise ValueError("ACL is in use")
            del acl[t[4]]
        elif t[:3] == ["set", "acl-plugin", "interface"]:
            name, way, idx, dele = t[3], t[4], int(t[6]), t[7:] == ["del"]
            if name not in st["if"]:
                raise ValueError("unknown input `%s'" % name)
            if str(idx) not in st.get("acl", {}):
                raise ValueError("ACL not found")
            b = st.setdefault("aclbind", {}).setdefault(name, {"input": [], "output": []})
            if dele:
                if idx not in b[way]:
                    raise ValueError("ACL not applied")
                b[way].remove(idx)
            else:
                if idx in b[way]:
                    raise ValueError("ACL already applied")
                b[way].append(idx)
        elif cmd == "show acl-plugin acl":
            for i, a in sorted(st.get("acl", {}).items(), key=lambda x: int(x[0])):
                out += "acl-index %s count %d tag {%s}\n" % (i, len(a["rules"]), a["tag"])
                for n, r in enumerate(a["rules"]):
                    out += "          %d: %s\n" % (n, r)
        elif cmd == "show acl-plugin interface":
            for n, b in sorted(st.get("aclbind", {}).items()):
                if not b["input"] and not b["output"]:
                    continue
                out += "sw_if_index %d:\n  input acl(s): %s\n  output acl(s): %s\n" % (
                    st["if"][n]["idx"], " ".join(map(str, b["input"])), " ".join(map(str, b["output"])))
        elif t[:3] == ["show", "synack-guard", "events"] or t[:2] == ["fake", "guard-events"]:
            g = st.setdefault("guard", {"mode": "off", "ifaces": {}, "prefixes": [], "config": {}, "used4": 0,
                                        "used6": 0, "errors": {}})
            if t[0] == "fake":
                g["events"] = json.loads(cmd.split(None, 2)[2])
            else:
                n = int(t[4]) if t[3:4] == ["count"] else 30
                out = "now: 1000.000\n" + "".join("event: %s\n" % e for e in g.get("events", [])[:n])
        elif t[:1] == ["synack-guard"] or cmd == "show synack-guard" or t[:2] == ["fake", "guard-errors"] \
                or t[:2] == ["fake", "guard-used"]:
            if os.environ.get("FAKEVPP_NO_GUARD") and t[0] != "fake":
                raise ValueError("unknown input `%s'" % cmd)
            g = st.setdefault("guard", {"mode": "off", "ifaces": {}, "prefixes": [], "config": {}, "used4": 0, "used6": 0,
                                        "errors": {}})
            if t[0] == "fake" and t[1] == "guard-errors":
                g["errors"] = json.loads(cmd.split(None, 2)[2])
            elif t[0] == "fake":
                g["used" + t[2]] = int(t[3])
            elif cmd == "show synack-guard":
                c = g["config"]
                out = "mode: %s\n" % g["mode"]
                out += ("config: ttl %s udp-ttl %s check-isn %s tcp-rst %s udp %s udp-frags %s reply-rst %s "
                        "reply-rst-pps %s udp-ports %s\n") % (
                    c.get("ttl", 60), c.get("udp-ttl", 30), c.get("check-isn", "on"), c.get("tcp-rst", "pass"),
                    c.get("udp", "on"), c.get("udp-frags", "pass"), c.get("reply-rst", "off"),
                    c.get("reply-rst-pps", 10000), c.get("udp-ports", "53"))
                for n, d in sorted(g["ifaces"].items()):
                    out += "interface: %s %s\n" % (n, d)
                for pf in sorted(g["prefixes"]):
                    out += "prefix: %s\n" % pf
                out += "table-v4: %d/%s\ntable-v6: %d/%s\n" % (g["used4"], c.get("table-v4", 4000000), g["used6"],
                                                             c.get("table-v6", 1000000))
            elif t[1] == "interface":
                if t[2] not in st["if"]:
                    raise ValueError("unknown input `%s'" % t[2])
                if t[3] not in ("in", "out"):
                    raise ValueError("unknown input `%s'" % t[3])
                if t[4:] == ["disable"]:
                    g["ifaces"].pop(t[2], None)
                else:
                    g["ifaces"][t[2]] = t[3]
            elif t[1] == "prefix":
                ipaddress.ip_network(t[2])
                if t[3:] == ["del"]:
                    if t[2] not in g["prefixes"]:
                        raise ValueError("prefix not found")
                    g["prefixes"].remove(t[2])
                elif t[2] not in g["prefixes"]:
                    g["prefixes"].append(t[2])
            elif t[1] == "mode":
                if t[2] not in ("off", "monitor", "enforce"):
                    raise ValueError("unknown input `%s'" % t[2])
                g["mode"] = t[2]
            elif t[1] == "config":
                if ("table-v4" in t or "table-v6" in t) and g["mode"] != "off":
                    raise ValueError("table sizes can be changed only when mode is off")
                for k in range(2, len(t) - 1, 2):
                    g["config"][t[k]] = t[k + 1]
            else:
                raise ValueError("unknown input `%s'" % cmd)
        elif cmd == "show errors":
            g = st.get("guard", {"errors": {}})
            out = "   Count                    Node                  Reason               Severity\n"
            for k, v in sorted(g["errors"].items()):
                node, reason = k.split("|")
                out += "%10d  %-28s %-24s error\n" % (v, node, reason)
        else:
            raise ValueError("unknown input `%s'" % cmd)
    except (ValueError, KeyError, IndexError, AssertionError) as ex:
        out = str(ex) or "error"
    save(st)
    return out


def ipcmd(argv):
    st = load()
    if argv[:2] != ["-n", "dataplane"]:
        sys.exit("fake ip: only -n dataplane")
    a = argv[2:]
    if a == ["-j", "link", "show"]:
        print(json.dumps([{"ifname": h, **({"ifalias": al} if al else {})} for h, al in st["linux"].items()]))
        return
    if a == ["-j", "addr", "show"]:
        out = []
        for h in st["linux"]:
            ai = []
            for x in st.get("laddr", {}).get(h, []):
                ip, pl = x.split("/")
                ai.append({"family": "inet6" if ":" in ip else "inet", "local": ip, "prefixlen": int(pl),
                           "scope": "global"})
            if st.get("ll", {}).get(h, True):
                ai.append({"family": "inet6", "local": "fe80::1", "prefixlen": 64, "scope": "link"})
            out.append({"ifname": h, "addr_info": ai})
        print(json.dumps(out))
        return
    if a[:1] == ["addr"] and a[1] in ("add", "del"):
        lst = st.setdefault("laddr", {}).setdefault(a[4], [])
        if a[1] == "add":
            if a[2] in lst:
                sys.exit("RTNETLINK answers: File exists")
            lst.append(a[2])
        else:
            if a[2] not in lst:
                sys.exit("RTNETLINK answers: Cannot assign requested address")
            lst.remove(a[2])
        # linux-nl: Linux -> VPP
        vpp = [n for n, hh in st["lcp"].items() if hh == a[4]]
        if vpp:
            va = st["if"][vpp[0]]["addrs"]
            if a[1] == "add" and a[2] not in va:
                va.append(a[2])
            if a[1] == "del" and a[2] in va:
                va.remove(a[2])
        save(st)
        return
    if a[:3] == ["link", "set", "dev"] and a[4:5] == ["addrgenmode"] and a[5] in ("none", "eui64"):
        if a[3] not in st["linux"]:
            sys.exit("Cannot find device \"%s\"" % a[3])
        if a[5] == "eui64":                 # kernel nadaje link-local, linux-cp włącza IPv6 w VPP
            st.setdefault("ll", {})[a[3]] = True
            for n, hh in st["lcp"].items():
                if hh == a[3]:
                    st["if"][n]["ip6"] = True
        save(st)
        return
    if a[:3] == ["-6", "addr", "flush"] and a[3] == "dev" and a[5:] == ["scope", "link"]:
        if a[4] not in st["linux"]:
            sys.exit("Cannot find device \"%s\"" % a[4])
        st.setdefault("ll", {})[a[4]] = False
        save(st)
        return
    if a[:3] == ["link", "set", "dev"] and a[4] == "alias":
        if a[3] not in st["linux"]:
            sys.exit("Cannot find device \"%s\"" % a[3])
        st["linux"][a[3]] = a[5]
        save(st)
        return
    sys.exit("fake ip: unsupported %s" % a)


if __name__ == "__main__":
    if os.path.basename(sys.argv[0]).startswith("fakeip"):
        ipcmd(sys.argv[1:])
    else:
        print(vppctl(" ".join(sys.argv[1:])))
