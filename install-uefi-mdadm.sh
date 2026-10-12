#!/usr/bin/env bash
# =============================================================================
# install-uefi-mdadm.sh — start z drugiego dysku RAID1 (mdadm) przy rozruchu UEFI
# Autor: PHU VIPHOST Przemysław Świderski <biuro@viphost.it>
#
# Partycja EFI (ESP, /boot/efi) nie jest w RAID — jest tylko na pierwszym dysku. Gdy ten dysk padnie,
# serwer nie wystartuje, mimo że RAID z systemem działa na drugim. Ten skrypt:
#   1. sprawdza stan RAID (/proc/mdstat),
#   2. kopiuje zawartość /boot/efi na partycję EFI drugiego dysku,
#   3. dodaje wpis w UEFI, żeby można było startować z drugiego dysku (kolejność startu: obecny wpis
#      zostaje pierwszy, nowy jest zapasowy),
#   4. instaluje automatyczną synchronizację: po każdej instalacji pakietów (apt) kopia ESP jest
#      odświeżana — aktualizacja GRUB-a lub shim trafia na oba dyski.
#
# Użycie (root):
#   bash install-uefi-mdadm.sh                 wykryj dyski, pokaż plan, zapytaj i wykonaj
#   bash install-uefi-mdadm.sh --dry-run       tylko pokaż, co zostałoby zrobione
#   bash install-uefi-mdadm.sh --yes           bez pytania
#   bash install-uefi-mdadm.sh --disk /dev/sdb wskaż drugi dysk ręcznie
#   bash install-uefi-mdadm.sh --no-hook       bez automatycznej synchronizacji po apt
#   bash install-uefi-mdadm.sh --sync-only     tylko skopiuj ESP (wołane przez hook apt)
#
# Niczego nie formatuje i nie zmienia partycji. Partycja EFI na drugim dysku musi istnieć i mieć system
# plików FAT (tak tworzy ją instalator Debiana przy RAID1 na dwóch dyskach). Można uruchamiać wielokrotnie.
# =============================================================================
set -Eeuo pipefail

ESP_GUID="c12a7328-f81f-11d2-ba4b-00a0c93ec93b"
SELF_DST=/usr/local/sbin/install-uefi-mdadm
HOOK=/etc/apt/apt.conf.d/99-router-esp-sync
DRY=0 YES=0 HOOK_ON=1 SYNC_ONLY=0 QUIET=0 DISK=""

c_ok=$'\e[32m' c_warn=$'\e[33m' c_err=$'\e[31m' c_off=$'\e[0m'
[[ -t 1 ]] || c_ok="" c_warn="" c_err="" c_off=""
say()  { ((QUIET)) || printf '  → %s\n' "$*"; }
ok()   { ((QUIET)) || printf '  %s[OK]%s %s\n' "$c_ok" "$c_off" "$*"; }
warn() { printf '  %s[UWAGA]%s %s\n' "$c_warn" "$c_off" "$*" >&2; }
die()  { printf '  %s[BŁĄD]%s %s\n' "$c_err" "$c_off" "$*" >&2; exit 1; }
run()  { if ((DRY)); then printf '    [dry-run] %s\n' "$*"; else "$@"; fi; }

while (($#)); do
  case "$1" in
    --dry-run) DRY=1 ;;
    --yes|-y) YES=1 ;;
    --no-hook) HOOK_ON=0 ;;
    --sync-only) SYNC_ONLY=1 ;;
    --quiet) QUIET=1 ;;
    --disk) shift; DISK=${1:-}; [[ -b $DISK ]] || die "--disk: $DISK nie jest urządzeniem blokowym" ;;
    -h|--help) sed -n '3,/^# =\{20,\}/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
    *) die "nieznany argument: $1 (zobacz --help)" ;;
  esac
  shift
done

((QUIET)) || printf 'install-uefi-mdadm.sh — Autor: %s\n' "PHU VIPHOST Przemysław Świderski <biuro@viphost.it>"
((EUID == 0)) || die "uruchom jako root"
[[ -d /sys/firmware/efi ]] || die "system nie wystartował w trybie UEFI — ten skrypt dotyczy tylko UEFI"
mountpoint -q /boot/efi || die "/boot/efi nie jest zamontowane"

# --- partycja EFI, z której system wystartował, i jej dysk
ESP_SRC=$(findmnt -no SOURCE /boot/efi)
SRC_DISK=/dev/$(lsblk -no PKNAME "$ESP_SRC" | head -1)
[[ -b $SRC_DISK ]] || die "nie ustalono dysku partycji $ESP_SRC"

# --- drugi dysk: z członków macierzy mdadm (dysk inny niż ten z bieżącym ESP)
disks_in_raid() {
  local md m
  for md in /dev/md/* /dev/md[0-9]*; do
    [[ -b $md ]] || continue
    for m in $(mdadm --detail "$md" 2>/dev/null | awk '/active sync/{print $NF}'); do
      lsblk -no PKNAME "$m" 2>/dev/null | head -1
    done
  done | sort -u | sed 's#^#/dev/#'
}
if [[ -z $DISK ]]; then
  mapfile -t others < <(disks_in_raid | grep -vx "$SRC_DISK" || true)
  ((${#others[@]})) || die "nie znaleziono drugiego dysku w RAID (mdadm) — podaj go: --disk /dev/sdX"
  ((${#others[@]} == 1)) || die "w RAID jest kilka innych dysków (${others[*]}) — wskaż jeden: --disk /dev/sdX"
  DISK=${others[0]}
fi
[[ $DISK != "$SRC_DISK" ]] || die "$DISK to dysk, z którego system wystartował — wskaż drugi dysk"

# --- partycja EFI na drugim dysku (typ ESP w tablicy GPT, system plików FAT)
ESP_DST=$(lsblk -lnpo NAME,PARTTYPE "$DISK" | awk -v g="$ESP_GUID" 'tolower($2)==g{print $1; exit}')
[[ -n $ESP_DST ]] || die "na $DISK nie ma partycji EFI (typ ESP). Utwórz ją jak na $SRC_DISK (ten sam rozmiar),
       sformatuj: mkfs.vfat -F32 <partycja> i uruchom skrypt ponownie"
fstype=$(lsblk -no FSTYPE "$ESP_DST")
[[ $fstype == vfat ]] || die "$ESP_DST nie ma systemu plików FAT (jest: ${fstype:-brak}). Sformatuj: mkfs.vfat -F32 $ESP_DST"
findmnt -rno TARGET "$ESP_DST" >/dev/null && die "$ESP_DST jest już zamontowana ($(findmnt -rno TARGET "$ESP_DST")) — odmontuj ją"
PART_NO=$(cat "/sys/class/block/${ESP_DST##*/}/partition")

# --- kopia ESP (wspólna dla instalacji i hooka apt)
sync_esp() {
  local mnt
  mnt=$(mktemp -d /run/esp-sync.XXXXXX)
  run mount -o umask=0077 "$ESP_DST" "$mnt"
  if ((DRY)); then
    printf '    [dry-run] kopia /boot/efi/ → %s (%s)\n' "$ESP_DST" "$mnt"
  elif command -v rsync >/dev/null; then
    rsync -a --delete --no-owner --no-group --modify-window=2 /boot/efi/ "$mnt/"
  else
    cp -a --no-preserve=ownership /boot/efi/. "$mnt/"
  fi
  run sync
  run umount "$mnt"
  rmdir "$mnt"
}

if ((SYNC_ONLY)); then
  sync_esp
  ok "ESP skopiowana: $ESP_SRC → $ESP_DST"
  exit 0
fi

# --- plan
printf '\nStan RAID (/proc/mdstat):\n'
sed 's/^/    /' /proc/mdstat
if grep -q '_' <(grep -o '\[[U_]*\]' /proc/mdstat); then
  warn "macierz nie jest kompletna ([U_] / [_U]) — dokończ odbudowę RAID przed kopiowaniem ESP"
  ((DRY)) || die "przerwano"
fi
grep -qE 'resync|recovery' /proc/mdstat && warn "trwa synchronizacja RAID — to nie przeszkadza, ESP jest poza RAID"

LOADER='\EFI\debian\shimx64.efi'
[[ -f /boot/efi/EFI/debian/shimx64.efi ]] || LOADER='\EFI\debian\grubx64.efi'
[[ -f /boot/efi/EFI/debian/${LOADER##*\\} ]] || die "brak /boot/efi/EFI/debian/${LOADER##*\\} — nietypowa instalacja, przerwano"
LABEL="debian-${DISK##*/}"

cat <<EOF

Plan:
  partycja EFI bieżąca:   $ESP_SRC (dysk $SRC_DISK)
  partycja EFI zapasowa:  $ESP_DST (dysk $DISK, partycja $PART_NO)
  1. kopia /boot/efi → $ESP_DST
  2. wpis UEFI "$LABEL" → $LOADER na $DISK (dopisany na KOŃCU kolejności startu)
  3. $( ((HOOK_ON)) && echo "automatyczna kopia ESP po każdej instalacji pakietów ($HOOK)" || echo "bez automatycznej kopii (--no-hook)")

EOF
if ((!DRY && !YES)); then
  ans=""
  read -rp "Wykonać? [t/N] " ans || true
  [[ $ans == [tTyY]* ]] || die "przerwano — nic nie zmieniono"
fi

# 1. kopia ESP
say "kopiuję /boot/efi → $ESP_DST"
sync_esp
ok "ESP skopiowana"

# 2. wpis UEFI (bez duplikatów; dotychczasowy wpis zostaje pierwszy)
command -v efibootmgr >/dev/null || run apt-get install -y efibootmgr
if ((DRY)) && ! command -v efibootmgr >/dev/null; then
  say "[dry-run] efibootmgr nie jest zainstalowany — wpis UEFI zostałby dodany po instalacji"
elif efibootmgr -v | grep -q "\* ${LABEL}[[:space:]]"; then
  ok "wpis UEFI \"$LABEL\" już istnieje — bez zmian"
else
  order=$(efibootmgr | sed -n 's/^BootOrder: //p')
  run efibootmgr -q -c -d "$DISK" -p "$PART_NO" -L "$LABEL" -l "$LOADER"
  if ((!DRY)); then
    num=$(efibootmgr | sed -n "s/^Boot\([0-9A-Fa-f]\{4\}\)\* ${LABEL}\$/\1/p" | head -1)
    [[ -n $num ]] || num=$(efibootmgr | sed -n "s/^Boot\([0-9A-Fa-f]\{4\}\)\* ${LABEL}[[:space:]].*/\1/p" | head -1)
    if [[ -n $num && -n $order ]]; then
      efibootmgr -q -o "$order,$num"            # efibootmgr -c stawia nowy wpis na początku — przywróć kolejność
    fi
    ok "wpis UEFI \"$LABEL\" (Boot$num) dodany na końcu kolejności startu"
  fi
fi

# 3. automatyczna kopia po aktualizacjach (grub-efi, shim)
if ((HOOK_ON)); then
  run install -m 755 "$(readlink -f "$0")" "$SELF_DST"
  if ((DRY)); then
    say "[dry-run] $HOOK: po każdym apt/dpkg: $SELF_DST --sync-only --quiet --disk $DISK"
  else
    cat >"$HOOK" <<EOF
// install-uefi-mdadm.sh: po każdej instalacji pakietów odśwież kopię partycji EFI na $DISK
// (aktualizacja GRUB-a lub shim trafia na oba dyski). Usunięcie tego pliku wyłącza kopię.
DPkg::Post-Invoke { "if [ -x $SELF_DST ]; then $SELF_DST --sync-only --quiet --disk $DISK || true; fi"; };
EOF
    ok "automatyczna kopia ESP po apt: $HOOK"
  fi
fi

printf '\n'
((DRY)) || efibootmgr -v | grep -i debian | sed 's/^/    /'
cat <<EOF

Gotowe. Sprawdzenie startu z drugiego dysku (w oknie serwisowym): w iDRAC / F11 (Boot Manager) wybierz
"$LABEL" — albo odłącz pierwszy dysk i uruchom serwer. RAID zostanie zdegradowany ([U_]) do czasu
ponownego podłączenia dysku; odbudowa: mdadm --manage /dev/mdX --add /dev/sdX2 (odpowiednia partycja).
EOF
