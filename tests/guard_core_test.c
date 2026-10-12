/* Testy synack_guard_core.h na hoście (bez VPP):  bash tests/test-guard-core.sh */
#include <stdio.h>
#include "../build/synack_guard/synack_guard_core.h"

static int checks, failures;
#define CHECK(cond)                                                                  \
  do {                                                                               \
    checks++;                                                                        \
    if (!(cond)) { failures++; printf("  BŁĄD  %s:%d  %s\n", __FILE__, __LINE__, #cond); } \
  } while (0)

#define SYN 0x02
#define ACK 0x10
#define RST 0x04
#define FIN 0x01

static void put16 (uint8_t *b, uint16_t v) { b[0] = v >> 8; b[1] = v & 0xff; }
static void put32 (uint8_t *b, uint32_t v) { b[0] = v >> 24; b[1] = v >> 16; b[2] = v >> 8; b[3] = v; }

/* IPv4 + TCP (ihl=5 albo więcej), zwraca długość */
static size_t
mk4_tcp (uint8_t *b, uint32_t src, uint32_t dst, uint16_t sp, uint16_t dp, uint8_t flags, uint32_t seq, uint32_t ack, int ihl)
{
  memset (b, 0, 128);
  b[0] = 0x40 | ihl; b[9] = 6;
  put32 (b + 12, src); put32 (b + 16, dst);
  uint8_t *t = b + ihl * 4;
  put16 (t, sp); put16 (t + 2, dp); put32 (t + 4, seq); put32 (t + 8, ack);
  t[12] = 0x50; t[13] = flags;
  return ihl * 4 + 20;
}

static size_t
mk4_udp (uint8_t *b, uint32_t src, uint32_t dst, uint16_t sp, uint16_t dp)
{
  memset (b, 0, 128);
  b[0] = 0x45; b[9] = 17;
  put32 (b + 12, src); put32 (b + 16, dst);
  put16 (b + 20, sp); put16 (b + 22, dp); put16 (b + 24, 8);
  return 28;
}

static size_t
mk6 (uint8_t *b, uint8_t next, uint16_t sp, uint16_t dp, uint8_t flags, uint32_t seq, uint32_t ack)
{
  memset (b, 0, 128);
  b[0] = 0x60; b[6] = next;
  b[8] = 0x20; b[9] = 0x01; b[10] = 0x0d; b[11] = 0xb8; b[23] = 1;      /* src 2001:db8::1 */
  b[24] = 0x20; b[25] = 0x01; b[26] = 0x0d; b[27] = 0xb8; b[39] = 2;    /* dst 2001:db8::2 */
  put16 (b + 40, sp); put16 (b + 42, dp);
  if (next == 6) { put32 (b + 44, seq); put32 (b + 48, ack); b[52] = 0x50; b[53] = flags; return 60; }
  put16 (b + 44, 8);
  return 48;
}

#define IP(a, b, c, d) (((uint32_t) (a) << 24) | ((b) << 16) | ((c) << 8) | (d))

static void
default_cfg (gc_cfg_t *c)
{
  gc_cfg_init (c);
}

static void
test_classify_v4 (void)
{
  uint8_t b[128]; gc_pkt_t p; size_t n;
  n = mk4_tcp (b, IP (203, 0, 113, 5), IP (8, 8, 8, 8), 40000, 443, SYN, 1000, 0, 5);
  CHECK (gc_classify_v4 (b, n, &p) == GC_TCP_SYN);
  CHECK (p.seq == 1000 && p.sport == 40000 && p.dport == 443 && p.proto == 6 && !p.is_v6);
  n = mk4_tcp (b, IP (8, 8, 8, 8), IP (203, 0, 113, 5), 443, 40000, SYN | ACK, 5000, 1001, 5);
  CHECK (gc_classify_v4 (b, n, &p) == GC_TCP_SYNACK);
  CHECK (p.ack == 1001 && p.seq == 5000);
  n = mk4_tcp (b, IP (8, 8, 8, 8), IP (203, 0, 113, 5), 443, 40000, RST | ACK, 0, 1001, 5);
  CHECK (gc_classify_v4 (b, n, &p) == GC_TCP_RST);
  n = mk4_tcp (b, IP (8, 8, 8, 8), IP (203, 0, 113, 5), 443, 40000, ACK, 1, 1, 5);
  CHECK (gc_classify_v4 (b, n, &p) == GC_NONE);
  n = mk4_tcp (b, IP (8, 8, 8, 8), IP (203, 0, 113, 5), 443, 40000, SYN | RST, 1, 1, 5);
  CHECK (gc_classify_v4 (b, n, &p) == GC_NONE);                         /* SYN+RST to śmieć */
  n = mk4_tcp (b, IP (8, 8, 8, 8), IP (203, 0, 113, 5), 443, 40000, FIN | ACK, 1, 1, 5);
  CHECK (gc_classify_v4 (b, n, &p) == GC_NONE);
  n = mk4_tcp (b, IP (8, 8, 8, 8), IP (203, 0, 113, 5), 443, 40000, SYN | ACK, 5000, 1001, 8);   /* IHL=8 (opcje IP) */
  CHECK (gc_classify_v4 (b, n, &p) == GC_TCP_SYNACK && p.ack == 1001);
  n = mk4_udp (b, IP (8, 8, 8, 8), IP (203, 0, 113, 5), 53, 40000);
  CHECK (gc_classify_v4 (b, n, &p) == GC_UDP && p.sport == 53 && p.dport == 40000 && p.proto == 17);
}

static void
test_classify_bounds_and_frags (void)
{
  uint8_t b[128]; gc_pkt_t p; size_t n;
  n = mk4_tcp (b, 1, 2, 1, 2, SYN | ACK, 1, 1, 5);
  CHECK (gc_classify_v4 (b, 19, &p) == GC_NONE);                        /* krótsze niż nagłówek IP */
  CHECK (gc_classify_v4 (b, 33, &p) == GC_NONE);                        /* TCP bez bajtu flag (20+13=33) */
  CHECK (gc_classify_v4 (b, 34, &p) == GC_TCP_SYNACK);                  /* dokładnie flagi */
  b[0] = 0x44;                                                          /* IHL < 5 */
  CHECK (gc_classify_v4 (b, n, &p) == GC_NONE);
  b[0] = 0x65;                                                          /* zła wersja */
  CHECK (gc_classify_v4 (b, n, &p) == GC_NONE);
  n = mk4_udp (b, 1, 2, 53, 9);
  CHECK (gc_classify_v4 (b, 27, &p) == GC_NONE);                        /* UDP krótsze niż 8 B nagłówka */
  b[6] = 0x00; b[7] = 0x10;                                             /* niepierwszy fragment (offset 16) */
  CHECK (gc_classify_v4 (b, n, &p) == GC_NONE && p.frag == 1 && p.proto == 17);
  n = mk4_tcp (b, 1, 2, 1, 2, SYN | ACK, 1, 1, 5);
  b[6] = 0x20;                                                          /* MF, offset 0: pierwszy fragment */
  CHECK (gc_classify_v4 (b, n, &p) == GC_TCP_SYNACK && p.frag == 0);
}

static void
test_classify_v6 (void)
{
  uint8_t b[128]; gc_pkt_t p; size_t n;
  n = mk6 (b, 6, 40000, 443, SYN, 77, 0);
  CHECK (gc_classify_v6 (b, n, &p) == GC_TCP_SYN && p.is_v6 && p.seq == 77 && p.sport == 40000);
  n = mk6 (b, 6, 443, 40000, SYN | ACK, 5, 78);
  CHECK (gc_classify_v6 (b, n, &p) == GC_TCP_SYNACK && p.ack == 78);
  CHECK (gc_classify_v6 (b, 53, &p) == GC_NONE);                        /* za krótkie */
  n = mk6 (b, 17, 53, 40000, 0, 0, 0);
  CHECK (gc_classify_v6 (b, n, &p) == GC_UDP && p.sport == 53);
  n = mk6 (b, 0, 1, 2, 0, 0, 0);                                        /* hop-by-hop: nagłówek rozszerzeń */
  CHECK (gc_classify_v6 (b, n, &p) == GC_NONE);
  n = mk6 (b, 44, 1, 2, 0, 0, 0);                                       /* nagłówek fragmentu */
  CHECK (gc_classify_v6 (b, n, &p) == GC_NONE);
}

static void
test_keys_and_values (void)
{
  uint8_t b1[128], b2[128]; gc_pkt_t out, in; gc_key4_t k1, k2; size_t n;
  n = mk4_tcp (b1, IP (203, 0, 113, 5), IP (8, 8, 8, 8), 40000, 443, SYN, 1000, 0, 5);
  gc_classify_v4 (b1, n, &out);
  n = mk4_tcp (b2, IP (8, 8, 8, 8), IP (203, 0, 113, 5), 443, 40000, SYN | ACK, 5000, 1001, 5);
  gc_classify_v4 (b2, n, &in);
  gc_key4_out (&k1, &out);
  gc_key4_in (&k2, &in);
  CHECK (k1.k[0] == k2.k[0] && k1.k[1] == k2.k[1]);                     /* ta sama czwórka z obu stron */
  n = mk4_tcp (b2, IP (8, 8, 8, 8), IP (203, 0, 113, 5), 443, 40001, SYN | ACK, 5000, 1001, 5);
  gc_classify_v4 (b2, n, &in);
  gc_key4_in (&k2, &in);
  CHECK (k1.k[0] != k2.k[0] || k1.k[1] != k2.k[1]);                     /* inny port klienta */
  n = mk4_udp (b2, IP (8, 8, 8, 8), IP (203, 0, 113, 5), 443, 40000);
  gc_classify_v4 (b2, n, &in);
  gc_key4_in (&k2, &in);
  CHECK (k1.k[1] != k2.k[1]);                                           /* UDP i TCP to różne klucze */

  gc_key6_t a, c; uint8_t s6[128], r6[128]; gc_pkt_t o6, i6;
  n = mk6 (s6, 6, 40000, 443, SYN, 9, 0);
  gc_classify_v6 (s6, n, &o6);
  memset (r6, 0, sizeof r6);
  n = mk6 (r6, 6, 443, 40000, SYN | ACK, 1, 10);
  memcpy (r6 + 8, s6 + 24, 16); memcpy (r6 + 24, s6 + 8, 16);           /* odwrócone adresy */
  gc_classify_v6 (r6, n, &i6);
  gc_key6_out (&a, &o6);
  gc_key6_in (&c, &i6);
  CHECK (memcmp (&a, &c, sizeof a) == 0);

  uint64_t v = gc_val_pack (0xdeadbeefu, 1234);
  CHECK (gc_val_isn (v) == 0xdeadbeefu && gc_val_ts (v) == 1234);
}

static void
test_verdicts (void)
{
  gc_cfg_t c; gc_pkt_t p; uint8_t b[128]; size_t n; uint64_t val = gc_val_pack (1000, 100);
  default_cfg (&c);
  n = mk4_tcp (b, IP (8, 8, 8, 8), IP (203, 0, 113, 5), 443, 40000, SYN | ACK, 5000, 1001, 5);
  gc_classify_v4 (b, n, &p);
  CHECK (gc_in_need_lookup (&p, &c));
  CHECK (gc_in_verdict (&p, &c, 0, 0, 100) == GC_V_NO_FLOW);
  CHECK (gc_in_verdict (&p, &c, 1, val, 110) == GC_V_PASS);
  CHECK (gc_in_verdict (&p, &c, 1, val, 100 + 60) == GC_V_PASS);        /* dokładnie TTL */
  CHECK (gc_in_verdict (&p, &c, 1, val, 100 + 61) == GC_V_NO_FLOW);     /* po TTL */
  CHECK (gc_in_verdict (&p, &c, 1, val, 90) == GC_V_PASS);              /* zegar „przed” wpisem nie wygasza */
  n = mk4_tcp (b, IP (8, 8, 8, 8), IP (203, 0, 113, 5), 443, 40000, SYN | ACK, 5000, 4242, 5);
  gc_classify_v4 (b, n, &p);
  CHECK (gc_in_verdict (&p, &c, 1, val, 110) == GC_V_BAD_ISN);
  c.check_isn = 0;
  CHECK (gc_in_verdict (&p, &c, 1, val, 110) == GC_V_PASS);
  c.check_isn = 1;

  /* RST: domyślnie nie podlega sprawdzaniu */
  n = mk4_tcp (b, IP (8, 8, 8, 8), IP (203, 0, 113, 5), 443, 40000, RST | ACK, 0, 1001, 5);
  gc_classify_v4 (b, n, &p);
  CHECK (!gc_in_need_lookup (&p, &c));
  CHECK (gc_in_verdict (&p, &c, 0, 0, 100) == GC_V_IGNORE);
  c.rst_handshake = 1;
  CHECK (gc_in_need_lookup (&p, &c));
  CHECK (gc_in_verdict (&p, &c, 0, 0, 100) == GC_V_NO_FLOW);
  CHECK (gc_in_verdict (&p, &c, 1, val, 110) == GC_V_PASS);             /* RST+ACK z ack = ISN+1 */
  n = mk4_tcp (b, IP (8, 8, 8, 8), IP (203, 0, 113, 5), 443, 40000, RST, 0, 0, 5);
  gc_classify_v4 (b, n, &p);
  CHECK (gc_in_verdict (&p, &c, 1, val, 110) == GC_V_PASS);             /* sam RST: bez sprawdzania ISN */

  /* UDP z portów amplifikacji */
  n = mk4_udp (b, IP (8, 8, 8, 8), IP (203, 0, 113, 5), 53, 40000);
  gc_classify_v4 (b, n, &p);
  CHECK (gc_in_need_lookup (&p, &c));
  CHECK (gc_in_verdict (&p, &c, 0, 0, 100) == GC_V_NO_FLOW);
  uint64_t uval = gc_val_pack (0, 100);
  CHECK (gc_in_verdict (&p, &c, 1, uval, 120) == GC_V_PASS);
  CHECK (gc_in_verdict (&p, &c, 1, uval, 100 + 31) == GC_V_NO_FLOW);    /* udp_ttl = 30 */
  n = mk4_udp (b, IP (8, 8, 8, 8), IP (203, 0, 113, 5), 5060, 40000);   /* port spoza listy */
  gc_classify_v4 (b, n, &p);
  CHECK (!gc_in_need_lookup (&p, &c));
  CHECK (gc_in_verdict (&p, &c, 0, 0, 100) == GC_V_IGNORE);
  c.udp_enabled = 0;
  n = mk4_udp (b, IP (8, 8, 8, 8), IP (203, 0, 113, 5), 53, 40000);
  gc_classify_v4 (b, n, &p);
  CHECK (gc_in_verdict (&p, &c, 0, 0, 100) == GC_V_IGNORE);
  c.udp_enabled = 1;

  /* niepierwsze fragmenty UDP */
  n = mk4_udp (b, IP (8, 8, 8, 8), IP (203, 0, 113, 5), 53, 40000);
  b[6] = 0x00; b[7] = 0x10;
  gc_classify_v4 (b, n, &p);
  CHECK (gc_in_verdict (&p, &c, 0, 0, 100) == GC_V_IGNORE);             /* domyślnie pass */
  c.udp_frags_drop = 1;
  CHECK (gc_in_verdict (&p, &c, 0, 0, 100) == GC_V_FRAG_DROP);
  c.udp_frags_drop = 0;

  /* SYN i UDP wychodzące: co zapisujemy */
  n = mk4_tcp (b, IP (203, 0, 113, 5), IP (8, 8, 8, 8), 40000, 443, SYN, 1000, 0, 5);
  gc_classify_v4 (b, n, &p);
  CHECK (gc_out_action (&p, &c) == GC_OUT_RECORD_TCP);
  n = mk4_udp (b, IP (203, 0, 113, 5), IP (8, 8, 8, 8), 40000, 53);
  gc_classify_v4 (b, n, &p);
  CHECK (gc_out_action (&p, &c) == GC_OUT_RECORD_UDP);
  n = mk4_udp (b, IP (203, 0, 113, 5), IP (8, 8, 8, 8), 40000, 5060);
  gc_classify_v4 (b, n, &p);
  CHECK (gc_out_action (&p, &c) == GC_OUT_IGNORE);
  n = mk4_tcp (b, IP (203, 0, 113, 5), IP (8, 8, 8, 8), 40000, 443, ACK, 1000, 1, 5);
  gc_classify_v4 (b, n, &p);
  CHECK (gc_out_action (&p, &c) == GC_OUT_IGNORE);

  /* decyzja o odrzuceniu zależy od trybu */
  CHECK (!gc_should_drop (&c, GC_V_NO_FLOW));                           /* monitor */
  c.enforce = 1;
  CHECK (gc_should_drop (&c, GC_V_NO_FLOW) && gc_should_drop (&c, GC_V_BAD_ISN) && gc_should_drop (&c, GC_V_FRAG_DROP));
  CHECK (!gc_should_drop (&c, GC_V_PASS) && !gc_should_drop (&c, GC_V_IGNORE));
}

static void
test_ports (void)
{
  gc_cfg_t c; default_cfg (&c);
  const uint16_t def[] = { 19, 53, 111, 123, 137, 161, 389, 1900, 3702, 5353, 11211 };
  for (size_t i = 0; i < sizeof def / sizeof def[0]; i++) CHECK (gc_port_test (&c, def[i]));
  CHECK (!gc_port_test (&c, 80) && !gc_port_test (&c, 0) && !gc_port_test (&c, 65535));
  gc_port_set (&c, 65535); gc_port_set (&c, 0);
  CHECK (gc_port_test (&c, 65535) && gc_port_test (&c, 0));
  gc_ports_clear (&c);
  CHECK (!gc_port_test (&c, 53));
}

static void
test_prefixes_v4 (void)
{
  gc_pset4_t s; memset (&s, 0, sizeof s);
  uint32_t a[] = { IP (203, 0, 113, 0), IP (198, 51, 100, 7), IP (10, 0, 0, 0), IP (203, 0, 113, 128) };
  uint8_t l[] = { 24, 32, 8, 25 };
  CHECK (gc_pset4_build (&s, a, l, 4) == 0);
  CHECK (gc_pset4_lookup (&s, IP (203, 0, 113, 77)));
  CHECK (gc_pset4_lookup (&s, IP (203, 0, 113, 200)));
  CHECK (!gc_pset4_lookup (&s, IP (203, 0, 114, 1)));
  CHECK (gc_pset4_lookup (&s, IP (198, 51, 100, 7)));
  CHECK (!gc_pset4_lookup (&s, IP (198, 51, 100, 8)));
  CHECK (gc_pset4_lookup (&s, IP (10, 255, 255, 255)));
  CHECK (!gc_pset4_lookup (&s, IP (11, 0, 0, 0)));
  gc_pset4_free (&s);
  CHECK (!gc_pset4_lookup (&s, IP (10, 0, 0, 1)));                      /* pusty zbiór nic nie obejmuje */

  uint32_t z[] = { 0 }; uint8_t zl[] = { 0 };                           /* 0.0.0.0/0 obejmuje wszystko */
  CHECK (gc_pset4_build (&s, z, zl, 1) == 0 && gc_pset4_lookup (&s, IP (1, 2, 3, 4)) && gc_pset4_lookup (&s, 0));
  gc_pset4_free (&s);

  uint32_t many[12]; uint8_t ml[12];                                    /* za dużo różnych długości prefiksów */
  for (int i = 0; i < 12; i++) { many[i] = IP (10, i, 0, 0); ml[i] = 16 + i; }
  CHECK (gc_pset4_build (&s, many, ml, 12) == -1);
  gc_pset4_free (&s);

  uint32_t big[3000]; uint8_t bl[3000];                                 /* wiele prefiksów tej samej długości */
  for (int i = 0; i < 3000; i++) { big[i] = IP (100, i >> 8, i & 255, 0); bl[i] = 24; }
  CHECK (gc_pset4_build (&s, big, bl, 3000) == 0);
  int hits = 0;
  for (int i = 0; i < 3000; i++) hits += gc_pset4_lookup (&s, IP (100, i >> 8, i & 255, 9));
  CHECK (hits == 3000 && !gc_pset4_lookup (&s, IP (101, 0, 0, 9)));
  gc_pset4_free (&s);
}

static void
test_prefixes_v6 (void)
{
  gc_pset6_t s; memset (&s, 0, sizeof s);
  uint64_t hi[] = { 0x20010db800010000ull, 0x20010db800020000ull };
  uint64_t lo[] = { 0, 5 };
  uint8_t l[] = { 48, 128 };
  CHECK (gc_pset6_build (&s, hi, lo, l, 2) == 0);
  CHECK (gc_pset6_lookup (&s, 0x20010db800010000ull, 0x1234));
  CHECK (gc_pset6_lookup (&s, 0x20010db80001ffffull, ~0ull));
  CHECK (!gc_pset6_lookup (&s, 0x20010db800030000ull, 0));
  CHECK (gc_pset6_lookup (&s, 0x20010db800020000ull, 5));
  CHECK (!gc_pset6_lookup (&s, 0x20010db800020000ull, 6));
  gc_pset6_free (&s);
}

/* niezależne liczenie sumy kontrolnej (RFC 1071) do sprawdzenia pakietów RST */
static uint16_t
ref_csum (const uint8_t *a, size_t n, uint32_t sum)
{
  for (size_t i = 0; i + 1 < n; i += 2) sum += (uint32_t) (a[i] << 8 | a[i + 1]);
  if (n & 1) sum += (uint32_t) a[n - 1] << 8;
  while (sum >> 16) sum = (sum & 0xffff) + (sum >> 16);
  return (uint16_t) sum;
}

static int
tcp_csum_ok (const uint8_t *ip, int v6)
{
  uint32_t ps = 0;
  const uint8_t *t;
  if (v6)
    {
      for (int i = 8; i < 40; i += 2) ps += (uint32_t) (ip[i] << 8 | ip[i + 1]);
      ps += 20 + 6; t = ip + 40;
    }
  else
    {
      for (int i = 12; i < 20; i += 2) ps += (uint32_t) (ip[i] << 8 | ip[i + 1]);
      ps += 20 + 6; t = ip + 20;
    }
  return ref_csum (t, 20, ps) == 0xffff;
}

static void
test_reply_rst_decision (void)
{
  gc_cfg_t c; gc_pkt_t p; uint8_t b[128]; size_t n;
  default_cfg (&c);
  CHECK (c.reply_rst == 0 && c.reply_rst_pps == 10000);          /* domyślnie wyłączone */
  n = mk4_tcp (b, IP (8, 8, 8, 8), IP (203, 0, 113, 5), 80, 40000, SYN | ACK, 7, 1001, 5);
  gc_classify_v4 (b, (uint32_t) n, &p);
  CHECK (!gc_want_rst (&p, &c, GC_V_NO_FLOW));
  c.reply_rst = 1;
  CHECK (gc_want_rst (&p, &c, GC_V_NO_FLOW));
  CHECK (!gc_want_rst (&p, &c, GC_V_BAD_ISN));                   /* zły ISN: nigdy RST */
  CHECK (!gc_want_rst (&p, &c, GC_V_PASS));
  n = mk4_tcp (b, IP (8, 8, 8, 8), IP (203, 0, 113, 5), 80, 40000, RST | ACK, 7, 1001, 5);
  gc_classify_v4 (b, (uint32_t) n, &p);
  CHECK (!gc_want_rst (&p, &c, GC_V_NO_FLOW));                   /* na RST nie odpowiadamy */
  n = mk4_udp (b, IP (8, 8, 8, 8), IP (203, 0, 113, 5), 53, 40000);
  gc_classify_v4 (b, (uint32_t) n, &p);
  CHECK (!gc_want_rst (&p, &c, GC_V_NO_FLOW));                   /* ani na UDP */
}

static void
test_rate_limit (void)
{
  gc_rl_t rl; memset (&rl, 0, sizeof rl);
  int got = 0;
  for (int i = 0; i < 1000; i++) got += gc_rl_take (&rl, 10.0, 100.0);
  CHECK (got == 100);                                            /* zapas = 1 s limitu */
  got = 0;
  for (int i = 0; i < 1000; i++) got += gc_rl_take (&rl, 10.5, 100.0);
  CHECK (got == 50);                                             /* po 0,5 s dochodzi 50 */
  got = 0;
  for (int i = 0; i < 1000; i++) got += gc_rl_take (&rl, 100.0, 100.0);
  CHECK (got == 100);                                            /* zapas nie rośnie ponad limit */
  CHECK (gc_rl_take (&rl, 200.0, 0.0) == 0);                     /* limit 0 = nic */
}

static void
test_make_rst_v4 (void)
{
  uint8_t b[128]; gc_pkt_t p;
  size_t n = mk4_tcp (b, IP (8, 8, 8, 8), IP (203, 0, 113, 5), 443, 40000, SYN | ACK, 7, 0x12345678, 6);
  n += 8;                                                        /* opcje IP (ihl=6) i 8 bajtów „opcji TCP” */
  gc_classify_v4 (b, (uint32_t) n, &p);
  uint32_t len = gc_make_rst (b, (uint32_t) n, &p);
  CHECK (len == 40);
  CHECK (b[0] == 0x45 && gc_be16 (b + 2) == 40 && b[8] == 64 && b[9] == 6);
  CHECK (gc_be32 (b + 12) == IP (203, 0, 113, 5) && gc_be32 (b + 16) == IP (8, 8, 8, 8));
  CHECK (ref_csum (b, 20, 0) == 0xffff);                         /* suma nagłówka IPv4 */
  CHECK (gc_be16 (b + 20) == 40000 && gc_be16 (b + 22) == 443);
  CHECK (gc_be32 (b + 24) == 0x12345678 && gc_be32 (b + 28) == 0); /* seq = ack z SYN-ACK, bez ACK */
  CHECK (b[32] == 0x50 && b[33] == RST && gc_be16 (b + 34) == 0);
  CHECK (tcp_csum_ok (b, 0));
  CHECK (gc_make_rst (b, 39, &p) == 0);                          /* za krótki bufor */
}

static void
test_make_rst_v6 (void)
{
  uint8_t b[128]; gc_pkt_t p;
  size_t n = mk6 (b, 6, 443, 40000, SYN | ACK, 7, 0xdeadbeef);
  gc_classify_v6 (b, (uint32_t) n, &p);
  uint32_t len = gc_make_rst (b, (uint32_t) n, &p);
  CHECK (len == 60);
  CHECK ((b[0] >> 4) == 6 && gc_be16 (b + 4) == 20 && b[6] == 6 && b[7] == 64);
  CHECK (b[23] == 2 && b[39] == 1);                              /* adresy zamienione */
  CHECK (gc_be16 (b + 40) == 40000 && gc_be16 (b + 42) == 443 && gc_be32 (b + 44) == 0xdeadbeef);
  CHECK (b[53] == RST);
  CHECK (tcp_csum_ok (b, 1));
}

static void
test_event_ring (void)
{
  gc_evring_t r; memset (&r, 0, sizeof r);
  gc_pkt_t p; uint8_t b[128];
  size_t n = mk4_tcp (b, IP (8, 8, 8, 8), IP (203, 0, 113, 5), 443, 40000, SYN | ACK, 7, 1001, 5);
  gc_classify_v4 (b, (uint32_t) n, &p);
  for (int i = 0; i < GC_EV_RING + 10; i++)
    gc_evring_push (&r, &p, GC_V_NO_FLOW, GC_ACT_DROP, (double) i);
  CHECK (r.n == GC_EV_RING);                                     /* pełny pierścień, nie rośnie */
  const gc_ev_t *last = &r.ev[(r.head + GC_EV_RING - 1) % GC_EV_RING];
  CHECK (last->t == (double) (GC_EV_RING + 9));                  /* najnowszy */
  CHECK (last->sport == 443 && last->dport == 40000 && last->cls == GC_TCP_SYNACK);
  CHECK (last->verdict == GC_V_NO_FLOW && last->action == GC_ACT_DROP && !last->is_v6);
  CHECK (memcmp (last->src, p.src, 16) == 0 && memcmp (last->dst, p.dst, 16) == 0);
  const gc_ev_t *oldest = &r.ev[r.head];
  CHECK (oldest->t == 10.0);                                     /* najstarsze nadpisane */
}

int
main (void)
{
  test_classify_v4 ();
  test_classify_bounds_and_frags ();
  test_classify_v6 ();
  test_keys_and_values ();
  test_verdicts ();
  test_ports ();
  test_prefixes_v4 ();
  test_prefixes_v6 ();
  test_reply_rst_decision ();
  test_rate_limit ();
  test_make_rst_v4 ();
  test_make_rst_v6 ();
  test_event_ring ();
  printf ("Wynik guard-core: %d OK, %d błędów\n", checks - failures, failures);
  return failures != 0;
}
