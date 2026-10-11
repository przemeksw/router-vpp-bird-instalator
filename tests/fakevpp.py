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
