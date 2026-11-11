// pqbox: dump chiffré vers une clé publique post-quantique.
//
// Schéma (suite 1) :
//   - KEM hybride : ML-KEM-768 (FIPS 203) + X25519 éphémère
//   - KDF         : HKDF-SHA256 sur (ss_mlkem || ss_x25519)
//   - Chiffrement : AES-256-GCM, chunks de 1 Mio, nonce = préfixe(8)||compteur(4)
//   - Clé privée  : scellée par PBKDF2-HMAC-SHA256 (1 000 000 itérations) + AES-256-GCM
//
// Aucune primitive asymétrique cassable par Shor : ML-KEM protège contre le
// quantique, X25519 ne sert que de filet classique si ML-KEM tombait.
// AES-256-GCM ne perd que 1 bit de sécurité face à Grover (128 bits effectifs).
//
// Fichiers :
//   publique : pqbox-public-key-v1 + base64(x25519_pk || mlkem_ek)
//   privée   : pqbox-private-key-v1 + iter + salt + nonce + base64(AES-GCM(...))
//   archive  : en-tête binaire PQB1 puis chunks AEAD
package main

import (
	"bufio"
	"bytes"
	"crypto/aes"
	"crypto/cipher"
	"crypto/ecdh"
	"crypto/hkdf"
	"crypto/mlkem"
	"crypto/pbkdf2"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

const (
	version     = "1.0.0"
	magic       = "PQB1"
	suiteHybrid = 1
	chunkSize   = 1 << 20
	noncePrefix = 8

	pubMagic = "pqbox-public-key-v1"
	keyMagic = "pqbox-private-key-v1"

	x25519Size = 32
	mlkemEK    = 1184
	mlkemCT    = 1088
	mlkemSeed  = 64

	pbkdf2Iter = 1_000_000
	label      = "pqbox v1"
)

var hdrLen = 4 + 1 + 4 + 32 + x25519Size + mlkemCT + noncePrefix

// ---------- clés ----------

type publicKey struct {
	x  []byte // 32
	ek *mlkem.EncapsulationKey768
}

func (p *publicKey) marshal() []byte { return append(append([]byte{}, p.x...), p.ek.Bytes()...) }

func parsePublic(b []byte) (*publicKey, error) {
	if len(b) != x25519Size+mlkemEK {
		return nil, fmt.Errorf("clé publique: %d octets, attendu %d", len(b), x25519Size+mlkemEK)
	}
	ek, err := mlkem.NewEncapsulationKey768(b[x25519Size:])
	if err != nil {
		return nil, fmt.Errorf("clé ML-KEM invalide: %w", err)
	}
	return &publicKey{x: b[:x25519Size], ek: ek}, nil
}

type privateKey struct {
	x    []byte // 32
	seed []byte // 64
	dk   *mlkem.DecapsulationKey768
}

func (p *privateKey) marshal() []byte {
	return append(append([]byte{}, p.x...), p.seed...)
}

func parsePrivate(b []byte) (*privateKey, error) {
	if len(b) != x25519Size+mlkemSeed {
		return nil, fmt.Errorf("clé privée: %d octets, attendu %d", len(b), x25519Size+mlkemSeed)
	}
	dk, err := mlkem.NewDecapsulationKey768(b[x25519Size:])
	if err != nil {
		return nil, fmt.Errorf("graine ML-KEM invalide: %w", err)
	}
	return &privateKey{x: b[:x25519Size], seed: b[x25519Size:], dk: dk}, nil
}

func newKeypair() (*publicKey, *privateKey, error) {
	seed := make([]byte, mlkemSeed)
	if _, err := rand.Read(seed); err != nil {
		return nil, nil, err
	}
	dk, err := mlkem.NewDecapsulationKey768(seed)
	if err != nil {
		return nil, nil, err
	}
	curve := ecdh.X25519()
	sk, err := curve.GenerateKey(rand.Reader)
	if err != nil {
		return nil, nil, err
	}
	priv := &privateKey{x: sk.Bytes(), seed: seed, dk: dk}
	pub := &publicKey{x: sk.PublicKey().Bytes(), ek: dk.EncapsulationKey()}
	return pub, priv, nil
}

// ---------- fichier de clé publique ----------

func writePublic(path string, pub *publicKey) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	body := fmt.Sprintf("%s\n%s\n", pubMagic, base64.StdEncoding.EncodeToString(pub.marshal()))
	return os.WriteFile(path, []byte(body), 0o644)
}

func loadPublic(path string) (*publicKey, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	lines := strings.Split(strings.TrimSpace(string(raw)), "\n")
	if len(lines) != 2 || strings.TrimSpace(lines[0]) != pubMagic {
		return nil, fmt.Errorf("%s: format inconnu", path)
	}
	b, err := base64.StdEncoding.DecodeString(strings.TrimSpace(lines[1]))
	if err != nil {
		return nil, err
	}
	return parsePublic(b)
}

// ---------- clé privée scellée ----------

func sealPrivate(path string, priv *privateKey, passphrase string) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	salt := make([]byte, 32)
	if _, err := rand.Read(salt); err != nil {
		return err
	}
	kek, err := pbkdf2.Key(sha256.New, passphrase, salt, pbkdf2Iter, 32)
	if err != nil {
		return err
	}
	gcm, err := newGCM(kek)
	if err != nil {
		return err
	}
	nonce := make([]byte, gcm.NonceSize())
	if _, err := rand.Read(nonce); err != nil {
		return err
	}
	ct := gcm.Seal(nil, nonce, priv.marshal(), []byte(keyMagic))
	body := fmt.Sprintf("%s\niter %d\nsalt %s\nnonce %s\ndata %s\n",
		keyMagic, pbkdf2Iter,
		base64.StdEncoding.EncodeToString(salt),
		base64.StdEncoding.EncodeToString(nonce),
		base64.StdEncoding.EncodeToString(ct))
	return os.WriteFile(path, []byte(body), 0o600)
}

func unsealPrivate(path, passphrase string) (*privateKey, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	fields := map[string]string{}
	lines := strings.Split(strings.TrimSpace(string(raw)), "\n")
	if len(lines) < 2 || strings.TrimSpace(lines[0]) != keyMagic {
		return nil, fmt.Errorf("%s: format inconnu", path)
	}
	for _, l := range lines[1:] {
		parts := strings.SplitN(strings.TrimSpace(l), " ", 2)
		if len(parts) == 2 {
			fields[parts[0]] = parts[1]
		}
	}
	var iter int
	if _, err := fmt.Sscanf(fields["iter"], "%d", &iter); err != nil || iter < 100000 {
		return nil, errors.New("fichier de clé: itérations invalides")
	}
	salt, err := base64.StdEncoding.DecodeString(fields["salt"])
	if err != nil {
		return nil, err
	}
	nonce, err := base64.StdEncoding.DecodeString(fields["nonce"])
	if err != nil {
		return nil, err
	}
	ct, err := base64.StdEncoding.DecodeString(fields["data"])
	if err != nil {
		return nil, err
	}
	kek, err := pbkdf2.Key(sha256.New, passphrase, salt, iter, 32)
	if err != nil {
		return nil, err
	}
	gcm, err := newGCM(kek)
	if err != nil {
		return nil, err
	}
	plain, err := gcm.Open(nil, nonce, ct, []byte(keyMagic))
	if err != nil {
		return nil, errors.New("mot de passe incorrect ou fichier de clé altéré")
	}
	return parsePrivate(plain)
}

// ---------- archive ----------

func newGCM(key []byte) (cipher.AEAD, error) {
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, err
	}
	return cipher.NewGCM(block)
}

func deriveKey(mlkemSS, x25519SS, salt []byte) ([]byte, error) {
	ikm := append(append([]byte{}, mlkemSS...), x25519SS...)
	return hkdf.Key(sha256.New, ikm, salt, label, 32)
}

func chunkAAD(hdr []byte, index uint32, last bool) []byte {
	aad := append([]byte{}, hdr...)
	aad = binary.BigEndian.AppendUint32(aad, index)
	if last {
		aad = append(aad, 1)
	} else {
		aad = append(aad, 0)
	}
	return aad
}

func chunkNonce(prefix []byte, index uint32) []byte {
	n := append([]byte{}, prefix...)
	return binary.BigEndian.AppendUint32(n, index)
}

func encryptStream(pub *publicKey, in io.Reader, out io.Writer) error {
	curve := ecdh.X25519()
	epriv, err := curve.GenerateKey(rand.Reader)
	if err != nil {
		return err
	}
	peer, err := curve.NewPublicKey(pub.x)
	if err != nil {
		return err
	}
	xss, err := epriv.ECDH(peer)
	if err != nil {
		return err
	}
	mss, ct := pub.ek.Encapsulate()

	salt := make([]byte, 32)
	if _, err := rand.Read(salt); err != nil {
		return err
	}
	key, err := deriveKey(mss, xss, salt)
	if err != nil {
		return err
	}
	gcm, err := newGCM(key)
	if err != nil {
		return err
	}
	prefix := make([]byte, noncePrefix)
	if _, err := rand.Read(prefix); err != nil {
		return err
	}

	hdr := make([]byte, 0, hdrLen)
	hdr = append(hdr, magic...)
	hdr = append(hdr, suiteHybrid)
	hdr = binary.BigEndian.AppendUint32(hdr, chunkSize)
	hdr = append(hdr, salt...)
	hdr = append(hdr, epriv.PublicKey().Bytes()...)
	hdr = append(hdr, ct...)
	hdr = append(hdr, prefix...)
	if len(hdr) != hdrLen {
		return fmt.Errorf("en-tête: %d octets, attendu %d", len(hdr), hdrLen)
	}
	w := bufio.NewWriterSize(out, 1<<20)
	if _, err := w.Write(hdr); err != nil {
		return err
	}

	var index uint32
	var pending []byte
	hasPending := false
	buf := make([]byte, chunkSize)
	emit := func(chunk []byte, last bool) error {
		sealed := gcm.Seal(nil, chunkNonce(prefix, index), chunk, chunkAAD(hdr, index, last))
		if _, err := w.Write(sealed); err != nil {
			return err
		}
		index++
		return nil
	}
	for {
		n, err := io.ReadFull(in, buf)
		switch {
		case err == nil:
			if hasPending {
				if e := emit(pending, false); e != nil {
					return e
				}
			}
			pending = append([]byte{}, buf[:n]...)
			hasPending = true
		case err == io.EOF:
			if hasPending {
				if e := emit(pending, true); e != nil {
					return e
				}
			} else if e := emit(nil, true); e != nil {
				return e
			}
			return w.Flush()
		case err == io.ErrUnexpectedEOF:
			if hasPending {
				if e := emit(pending, false); e != nil {
					return e
				}
			}
			if e := emit(append([]byte{}, buf[:n]...), true); e != nil {
				return e
			}
			return w.Flush()
		default:
			return err
		}
	}
}

func decryptStream(priv *privateKey, in io.Reader, out io.Writer) error {
	r := bufio.NewReaderSize(in, hdrLen+chunkSize+16)
	hdr := make([]byte, hdrLen)
	if _, err := io.ReadFull(r, hdr); err != nil {
		return fmt.Errorf("lecture de l'en-tête: %w", err)
	}
	if string(hdr[:4]) != magic {
		return errors.New("ce fichier n'est pas une archive pqbox")
	}
	if hdr[4] != suiteHybrid {
		return fmt.Errorf("suite inconnue: %d", hdr[4])
	}
	cs := binary.BigEndian.Uint32(hdr[5:9])
	if cs == 0 || cs > 64<<20 {
		return fmt.Errorf("taille de chunk invalide: %d", cs)
	}
	off := 9
	salt := hdr[off : off+32]
	off += 32
	epkBytes := hdr[off : off+x25519Size]
	off += x25519Size
	kemCT := hdr[off : off+mlkemCT]
	off += mlkemCT
	prefix := hdr[off : off+noncePrefix]

	curve := ecdh.X25519()
	epk, err := curve.NewPublicKey(epkBytes)
	if err != nil {
		return err
	}
	sk, err := curve.NewPrivateKey(priv.x)
	if err != nil {
		return err
	}
	xss, err := sk.ECDH(epk)
	if err != nil {
		return err
	}
	mss, err := priv.dk.Decapsulate(kemCT)
	if err != nil {
		return fmt.Errorf("décapsulation ML-KEM: %w", err)
	}
	key, err := deriveKey(mss, xss, salt)
	if err != nil {
		return err
	}
	gcm, err := newGCM(key)
	if err != nil {
		return err
	}

	w := bufio.NewWriterSize(out, 1<<20)
	ctBuf := make([]byte, int(cs)+16)
	var index uint32
	for {
		n, err := io.ReadFull(r, ctBuf)
		last := false
		switch {
		case err == nil:
			if _, perr := r.Peek(1); perr == io.EOF {
				last = true
			} else if perr != nil {
				return perr
			}
		case err == io.ErrUnexpectedEOF:
			last = true
		case err == io.EOF:
			return errors.New("archive tronquée: aucun chunk final")
		default:
			return err
		}
		if n < 16 {
			return errors.New("chunk invalide")
		}
		plain, err := gcm.Open(nil, chunkNonce(prefix, index), ctBuf[:n], chunkAAD(hdr, index, last))
		if err != nil {
			return fmt.Errorf("authentification du chunk %d échouée (clé, archive altérée ou tronquée)", index)
		}
		if _, err := w.Write(plain); err != nil {
			return err
		}
		index++
		if last {
			if _, perr := r.Peek(1); perr != io.EOF {
				return errors.New("données après le chunk final")
			}
			return w.Flush()
		}
	}
}

// ---------- mot de passe ----------

func stty(f *os.File, arg string) error {
	c := exec.Command("stty", arg)
	c.Stdin = f
	return c.Run()
}

func readPassphrase(prompt string) (string, error) {
	tty, err := os.OpenFile("/dev/tty", os.O_RDWR, 0)
	if err != nil {
		return "", errors.New("pas de terminal: lancer la commande dans un vrai shell (ou --insecure-passphrase-file pour les tests)")
	}
	defer tty.Close()
	if err := stty(tty, "-echo"); err != nil {
		fmt.Fprintln(os.Stderr, "avertissement: impossible de couper l'écho")
	} else {
		defer stty(tty, "echo")
	}
	fmt.Fprint(tty, prompt)
	line, err := bufio.NewReader(tty).ReadString('\n')
	fmt.Fprintln(tty)
	if err != nil && err != io.EOF {
		return "", err
	}
	return strings.TrimRight(line, "\r\n"), nil
}

func readPassphraseConfirmed() (string, error) {
	p1, err := readPassphrase("Mot de passe (ne s'affiche pas): ")
	if err != nil {
		return "", err
	}
	if len(p1) < 12 {
		return "", errors.New("mot de passe trop court: 20 caractères ou 6 mots minimum")
	}
	p2, err := readPassphrase("Confirmation: ")
	if err != nil {
		return "", err
	}
	if p1 != p2 {
		return "", errors.New("les deux saisies diffèrent")
	}
	return p1, nil
}

func mustPassphrase(flagPath string, confirm bool) (string, error) {
	if flagPath != "" {
		b, err := os.ReadFile(flagPath)
		if err != nil {
			return "", err
		}
		return strings.TrimRight(string(b), "\r\n"), nil
	}
	if confirm {
		return readPassphraseConfirmed()
	}
	return readPassphrase("Mot de passe: ")
}

func fingerprint(pub *publicKey) string {
	h := sha256.Sum256(pub.marshal())
	return hex.EncodeToString(h[:8])
}

// ---------- commandes ----------

func main() {
	if len(os.Args) < 2 {
		usage()
		os.Exit(2)
	}
	cmd := os.Args[1]
	args := os.Args[2:]

	switch cmd {
	case "keygen":
		fs := flag.NewFlagSet("keygen", flag.ExitOnError)
		pubOut := fs.String("pub", "backup.pub", "fichier de clé publique à écrire")
		keyOut := fs.String("key", "", "fichier de clé privée scellée à écrire (défaut: <pub>.key)")
		passFile := fs.String("insecure-passphrase-file", "", "TEST UNIQUEMENT: lire le mot de passe dans un fichier")
		force := fs.Bool("force", false, "écraser les fichiers existants")
		fs.Parse(args)
		keyPath := *keyOut
		if keyPath == "" {
			keyPath = strings.TrimSuffix(*pubOut, ".pub") + ".key"
		}
		if !*force {
			for _, p := range []string{*pubOut, keyPath} {
				if _, err := os.Stat(p); err == nil {
					fatal("%s existe déjà (utiliser --force)", p)
				}
			}
		}
		pub, priv, err := newKeypair()
		if err != nil {
			fatal("génération des clés: %v", err)
		}
		pass, err := mustPassphrase(*passFile, *passFile == "")
		if err != nil {
			fatal("%v", err)
		}
		if err := sealPrivate(keyPath, priv, pass); err != nil {
			fatal("écriture de la clé: %v", err)
		}
		if err := writePublic(*pubOut, pub); err != nil {
			fatal("écriture de la clé publique: %v", err)
		}
		fmt.Printf("clé publique : %s\nclé privée   : %s (scellée, 0600)\nempreinte    : %s\n",
			*pubOut, keyPath, fingerprint(pub))

	case "seal":
		fs := flag.NewFlagSet("seal", flag.ExitOnError)
		in := fs.String("in", "", "clé privée en clair (32+64 octets base64)")
		out := fs.String("out", "", "fichier scellé à écrire")
		passFile := fs.String("insecure-passphrase-file", "", "TEST UNIQUEMENT")
		fs.Parse(args)
		if *in == "" || *out == "" {
			fatal("seal: --in et --out requis")
		}
		raw, err := os.ReadFile(*in)
		if err != nil {
			fatal("%v", err)
		}
		b, err := base64.StdEncoding.DecodeString(strings.TrimSpace(string(raw)))
		if err != nil {
			fatal("clé en clair invalide: %v", err)
		}
		priv, err := parsePrivate(b)
		if err != nil {
			fatal("%v", err)
		}
		pass, err := mustPassphrase(*passFile, *passFile == "")
		if err != nil {
			fatal("%v", err)
		}
		if err := sealPrivate(*out, priv, pass); err != nil {
			fatal("%v", err)
		}
		fmt.Println("clé scellée:", *out)

	case "reseal":
		fs := flag.NewFlagSet("reseal", flag.ExitOnError)
		keyPath := fs.String("key", "", "clé privée scellée existante")
		out := fs.String("out", "", "nouveau fichier scellé (défaut: --key)")
		oldFile := fs.String("insecure-passphrase-file", "", "TEST UNIQUEMENT: ancien mot de passe dans un fichier")
		fs.Parse(args)
		if *keyPath == "" {
			fatal("reseal: --key requis")
		}
		dest := *out
		if dest == "" {
			dest = *keyPath
		}
		var old string
		var err error
		if *oldFile != "" {
			old, err = mustPassphrase(*oldFile, false)
		} else {
			old, err = readPassphrase("Ancien mot de passe: ")
		}
		if err != nil {
			fatal("%v", err)
		}
		priv, err := unsealPrivate(*keyPath, old)
		if err != nil {
			fatal("%v", err)
		}
		pass, err := readPassphraseConfirmed()
		if err != nil {
			fatal("%v", err)
		}
		if err := sealPrivate(dest, priv, pass); err != nil {
			fatal("%v", err)
		}
		fmt.Println("clé rescellée:", dest)

	case "pub":
		fs := flag.NewFlagSet("pub", flag.ExitOnError)
		keyPath := fs.String("key", "", "clé privée scellée")
		passFile := fs.String("insecure-passphrase-file", "", "TEST UNIQUEMENT")
		fs.Parse(args)
		if *keyPath == "" {
			fatal("pub: --key requis")
		}
		pass, err := mustPassphrase(*passFile, false)
		if err != nil {
			fatal("%v", err)
		}
		priv, err := unsealPrivate(*keyPath, pass)
		if err != nil {
			fatal("%v", err)
		}
		pub := &publicKey{x: nil, ek: priv.dk.EncapsulationKey()}
		curve := ecdh.X25519()
		sk, err := curve.NewPrivateKey(priv.x)
		if err != nil {
			fatal("%v", err)
		}
		pub.x = sk.PublicKey().Bytes()
		fmt.Printf("%s\n%s\n", pubMagic, base64.StdEncoding.EncodeToString(pub.marshal()))
		fmt.Fprintf(os.Stderr, "empreinte: %s\n", fingerprint(pub))

	case "encrypt":
		fs := flag.NewFlagSet("encrypt", flag.ExitOnError)
		recipient := fs.String("recipient", "", "fichier de clé publique")
		in := fs.String("in", "-", "entrée (- pour stdin)")
		out := fs.String("out", "-", "sortie (- pour stdout)")
		fs.Parse(args)
		if *recipient == "" {
			fatal("encrypt: --recipient requis")
		}
		pub, err := loadPublic(*recipient)
		if err != nil {
			fatal("%v", err)
		}
		fi, fo, closeIn, closeOut := openStreams(*in, *out)
		defer closeIn()
		defer closeOut()
		_ = fi
		_ = fo
		if err := encryptStream(pub, fi, fo); err != nil {
			fatal("chiffrement: %v", err)
		}

	case "decrypt":
		fs := flag.NewFlagSet("decrypt", flag.ExitOnError)
		keyPath := fs.String("key", "", "clé privée scellée")
		in := fs.String("in", "-", "entrée (- pour stdin)")
		out := fs.String("out", "-", "sortie (- pour stdout)")
		passFile := fs.String("insecure-passphrase-file", "", "TEST UNIQUEMENT")
		fs.Parse(args)
		if *keyPath == "" {
			fatal("decrypt: --key requis")
		}
		pass, err := mustPassphrase(*passFile, false)
		if err != nil {
			fatal("%v", err)
		}
		priv, err := unsealPrivate(*keyPath, pass)
		if err != nil {
			fatal("%v", err)
		}
		fi, fo, closeIn, closeOut := openStreams(*in, *out)
		defer closeIn()
		defer closeOut()
		if err := decryptStream(priv, fi, fo); err != nil {
			fatal("déchiffrement: %v", err)
		}

	case "inspect":
		fs := flag.NewFlagSet("inspect", flag.ExitOnError)
		in := fs.String("in", "-", "archive")
		fs.Parse(args)
		fi, _, closeIn, _ := openStreams(*in, "-")
		defer closeIn()
		hdr := make([]byte, hdrLen)
		if _, err := io.ReadFull(fi, hdr); err != nil {
			fatal("lecture: %v", err)
		}
		if string(hdr[:4]) != magic {
			fatal("pas une archive pqbox")
		}
		fmt.Printf("magic      : %s\nsuite      : %d (ML-KEM-768 + X25519, HKDF-SHA256, AES-256-GCM)\nchunk      : %d octets\nen-tête    : %d octets\n",
			magic, hdr[4], binary.BigEndian.Uint32(hdr[5:9]), hdrLen)

	case "selftest":
		runSelftest()

	case "version":
		fmt.Println("pqbox", version)

	default:
		usage()
		os.Exit(2)
	}
}

func openStreams(in, out string) (io.Reader, io.Writer, func(), func()) {
	var fi io.Reader = os.Stdin
	var fo io.Writer = os.Stdout
	closeIn := func() {}
	closeOut := func() {}
	if in != "-" {
		f, err := os.Open(in)
		if err != nil {
			fatal("%v", err)
		}
		fi = f
		closeIn = func() { f.Close() }
	}
	if out != "-" {
		f, err := os.OpenFile(out, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o600)
		if err != nil {
			fatal("%v", err)
		}
		fo = f
		closeOut = func() { f.Close() }
	} else if w, ok := fo.(*os.File); ok {
		_ = w
	}
	return fi, fo, closeIn, closeOut
}

func runSelftest() {
	fail := func(format string, a ...any) {
		fmt.Fprintf(os.Stderr, "ECHEC: "+format+"\n", a...)
		os.Exit(1)
	}
	pub, priv, err := newKeypair()
	if err != nil {
		fail("keygen: %v", err)
	}
	// clé publique sérialisée puis relue
	reloaded, err := parsePublic(pub.marshal())
	if err != nil {
		fail("relecture clé publique: %v", err)
	}
	// scellement / descellé
	dir, err := os.MkdirTemp("", "pqbox-selftest")
	if err != nil {
		fail("%v", err)
	}
	defer os.RemoveAll(dir)
	kpath := dir + "/k.key"
	if err := sealPrivate(kpath, priv, "correct horse battery staple"); err != nil {
		fail("seal: %v", err)
	}
	priv2, err := unsealPrivate(kpath, "correct horse battery staple")
	if err != nil {
		fail("unseal: %v", err)
	}
	if !bytes.Equal(priv2.marshal(), priv.marshal()) {
		fail("clé descellée différente")
	}
	if _, err := unsealPrivate(kpath, "mauvais mot de passe"); err == nil {
		fail("un mauvais mot de passe a été accepté")
	}

	// aller-retour sur plusieurs tailles, dont des multiples du chunk
	sizes := []int{0, 1, 15, 1000, chunkSize - 1, chunkSize, chunkSize + 1, 3*chunkSize + 7}
	for _, n := range sizes {
		plain := make([]byte, n)
		if _, err := rand.Read(plain); err != nil {
			fail("%v", err)
		}
		var box bytes.Buffer
		if err := encryptStream(pub, bytes.NewReader(plain), &box); err != nil {
			fail("chiffrement %d: %v", n, err)
		}
		var back bytes.Buffer
		if err := decryptStream(priv2, bytes.NewReader(box.Bytes()), &back); err != nil {
			fail("déchiffrement %d: %v", n, err)
		}
		if !bytes.Equal(plain, back.Bytes()) {
			fail("aller-retour %d: contenu différent", n)
		}
		// altération d'un octet au milieu
		if n > 0 {
			tampered := append([]byte{}, box.Bytes()...)
			tampered[hdrLen+n/2] ^= 0x01
			if err := decryptStream(priv2, bytes.NewReader(tampered), io.Discard); err == nil {
				fail("altération non détectée (%d)", n)
			}
		}
		// troncature
		if len(box.Bytes()) > hdrLen+1 {
			cut := box.Bytes()[:len(box.Bytes())-1]
			if err := decryptStream(priv2, bytes.NewReader(cut), io.Discard); err == nil {
				fail("troncature non détectée (%d)", n)
			}
		}
		// mauvaise clé
		otherPub, otherPriv, err := newKeypair()
		if err != nil {
			fail("%v", err)
		}
		_ = otherPub
		if err := decryptStream(otherPriv, bytes.NewReader(box.Bytes()), io.Discard); err == nil {
			fail("déchiffrement accepté avec une mauvaise clé")
		}
	}
	_ = reloaded
	fmt.Println("selftest OK: ML-KEM-768 + X25519, AES-256-GCM chunké, scellement PBKDF2, altération/troncature/mauvaise clé refusées")
}

func usage() {
	fmt.Fprintf(os.Stderr, `pqbox %s : chiffrement de dumps vers une clé publique post-quantique

  pqbox keygen  --pub backup.pub [--key backup.key]   crée la paire, scelle la privée
  pqbox seal    --in clair.b64 --out backup.key       scelle une clé existante
  pqbox encrypt --recipient backup.pub [-in f] [-out f]
  pqbox decrypt --key backup.key [-in f] [-out f]
  pqbox pub     --key backup.key                      réaffiche la clé publique
  pqbox inspect --in archive.pqbox
  pqbox selftest

Le mot de passe est demandé sur /dev/tty, jamais par argument ni variable.
`, version)
}

func fatal(format string, a ...any) {
	fmt.Fprintf(os.Stderr, "pqbox: "+format+"\n", a...)
	os.Exit(1)
}
