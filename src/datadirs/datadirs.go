package datadirs

import (
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

type DataDirs struct {
	Root        string
	VMS         string
	VHD         string
	ISOs        string
	Checkpoints string
	Logs        string
	Trash       string
}

// EnsureDataDirs crée l’arborescence gérée par OpenHVX.
// ⚠️ Ne supprime jamais ; crée uniquement.
// Place un fichier "DO-NOT-DELETE.txt" dans chaque dossier géré.
func EnsureDataDirs(basePath string) (DataDirs, error) {
	if basePath == "" {
		return DataDirs{}, fmt.Errorf("basePath empty")
	}
	base := filepath.Clean(basePath)
	root := filepath.Join(base, "openhvx")

	d := DataDirs{
		Root:        root,
		VMS:         filepath.Join(root, "VMS"),
		VHD:         filepath.Join(root, "VHD"),
		ISOs:        filepath.Join(root, "ISOs"),
		Checkpoints: filepath.Join(root, "Checkpoints"),
		Logs:        filepath.Join(root, "Logs"),
		Trash:       filepath.Join(root, "_trash"),
	}

	for _, p := range []string{d.Root, d.VMS, d.VHD, d.ISOs, d.Checkpoints, d.Logs, d.Trash} {
		if err := os.MkdirAll(p, 0o755); err != nil {
			return DataDirs{}, fmt.Errorf("mkdir %s: %w", p, err)
		}
	}
	_ = writeGuards(d) // non bloquant
	return d, nil
}

func writeGuards(d DataDirs) error {
	content := []byte(
		"Managed by OpenHVX. Do NOT delete this folder. " +
			"Any destructive operation must move targets into '_trash'.\n",
	)
	var firstErr error
	for _, dir := range []string{d.Root, d.VMS, d.VHD, d.ISOs, d.Checkpoints, d.Logs, d.Trash} {
		fp := filepath.Join(dir, "DO-NOT-DELETE.txt")
		if _, err := os.Stat(fp); err == nil {
			continue
		}
		if err := os.WriteFile(fp, content, 0o644); err != nil && firstErr == nil {
			firstErr = err
		}
	}
	return firstErr
}

// ---------- Chemins & garde-fous ----------

func canonicalize(p string) (string, error) {
	if p == "" {
		return "", errors.New("empty path")
	}
	abs, err := filepath.Abs(p)
	if err != nil {
		return "", err
	}
	return filepath.Clean(abs), nil
}

// isUnder vérifie si p est STRICTEMENT sous base (et pas égal).
func isUnder(p, base string) bool {
	p = filepath.Clean(p)
	base = filepath.Clean(base)
	if p == base {
		return false
	}
	rel, err := filepath.Rel(base, p)
	if err != nil {
		return false
	}
	if rel == ".." || strings.HasPrefix(rel, ".."+string(filepath.Separator)) {
		return false
	}
	// Evite les chemins absolus "relatifs"
	if filepath.IsAbs(rel) {
		return false
	}
	return true
}

// IsProtectedPath: renvoie true si p est un dossier racine géré (à ne jamais supprimer/déplacer).
func IsProtectedPath(p string, d DataDirs) bool {
	p = filepath.Clean(p)
	protect := map[string]struct{}{
		filepath.Clean(d.Root):        {},
		filepath.Clean(d.VMS):         {},
		filepath.Clean(d.VHD):         {},
		filepath.Clean(d.ISOs):        {},
		filepath.Clean(d.Checkpoints): {},
		filepath.Clean(d.Logs):        {},
		filepath.Clean(d.Trash):       {},
	}
	_, ok := protect[p]
	return ok
}

// AssertSafeTarget échoue si la cible est hors openhvx ou est un dossier protégé.
func AssertSafeTarget(target string, d DataDirs) error {
	canon, err := canonicalize(target)
	if err != nil {
		return err
	}
	if !isUnder(canon, d.Root) {
		return fmt.Errorf("unsafe target: %s is not under %s", canon, d.Root)
	}
	if IsProtectedPath(canon, d) {
		return fmt.Errorf("refuse to operate on protected dir: %s", canon)
	}
	return nil
}

// ---------- Corbeille interne (aucune suppression) ----------

// MoveToTrash déplace un fichier/dossier ciblé dans la corbeille interne (_trash).
// Si la cible est un dossier protégé ou hors Root, renvoie une erreur.
// Si déplacement impossible (ex: cross-device), renvoie une erreur (aucune suppression).
func MoveToTrash(target string, d DataDirs) (string, error) {
	if err := AssertSafeTarget(target, d); err != nil {
		return "", err
	}
	src, err := canonicalize(target)
	if err != nil {
		return "", err
	}
	ts := time.Now().UTC().Format("20060102-150405")
	rel, _ := filepath.Rel(d.Root, src)
	dst := filepath.Join(d.Trash, ts, rel)

	if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
		return "", fmt.Errorf("prepare trash dir: %w", err)
	}
	// Ne jamais écraser en trash : si collision, crée un nom unique
	uniqueDst, err := uniquePath(dst)
	if err != nil {
		return "", err
	}
	if err := os.Rename(src, uniqueDst); err != nil {
		return "", fmt.Errorf("move to trash failed: %w", err)
	}
	return uniqueDst, nil
}

// ---------- Noms uniques & opérations sans overwrite ----------

// uniquePath renvoie un chemin qui N’EXISTE PAS, basé sur p.
// p   => p (si libre)
// p.ext => p (si libre), sinon p (1).ext, p (2).ext, ... ; fallback suffixe timestamp si trop de collisions.
func uniquePath(p string) (string, error) {
	dir := filepath.Dir(p)
	base := filepath.Base(p)
	ext := filepath.Ext(base)
	name := strings.TrimSuffix(base, ext)

	try := func(candidate string) (string, bool) {
		if _, err := os.Lstat(candidate); err != nil {
			if os.IsNotExist(err) {
				return candidate, true
			}
			// autre erreur d’accès -> on considère non libre
		}
		return "", false
	}

	if cand, ok := try(p); ok {
		return cand, nil
	}

	// Boucle suffixée
	for i := 1; i <= 9999; i++ {
		c := filepath.Join(dir, fmt.Sprintf("%s (%d)%s", name, i, ext))
		if cand, ok := try(c); ok {
			return cand, nil
		}
	}

	// Fallback timestamp (très improbable d’y arriver)
	ts := time.Now().UTC().Format("20060102-150405.000")
	c := filepath.Join(dir, fmt.Sprintf("%s-%s%s", name, ts, ext))
	if cand, ok := try(c); ok {
		return cand, nil
	}
	return "", fmt.Errorf("unable to find a free name for %s", p)
}

// SafeMkdirAll crée un dossier sous Root, mais refuse d’écraser/renommer un dossier protégé.
// Utile pour créer des sous-dossiers VM (ex: VMS/<tenant>/<vm>).
func SafeMkdirAll(dir string, mode os.FileMode, d DataDirs) error {
	canon, err := canonicalize(dir)
	if err != nil {
		return err
	}
	// Autorisé uniquement SOUS Root et pas un protégé en tant que cible directe.
	if !isUnder(canon, d.Root) {
		return fmt.Errorf("mkdir outside managed root: %s", canon)
	}
	if IsProtectedPath(canon, d) {
		return fmt.Errorf("refuse to mkdir a protected dir: %s", canon)
	}
	return os.MkdirAll(canon, mode)
}

// SafeCreateFile crée un fichier en mode EXCLUSIF (pas d’overwrite).
// S’il existe, génère un nom unique (ex: "file (1).vhdx").
// Retourne le *os.File ouvert en écriture et le chemin final choisi.
func SafeCreateFile(dest string, perm os.FileMode, d DataDirs) (*os.File, string, error) {
	if err := AssertSafeTarget(dest, d); err != nil {
		return nil, "", err
	}
	destCanon, err := canonicalize(dest)
	if err != nil {
		return nil, "", err
	}
	if err := os.MkdirAll(filepath.Dir(destCanon), 0o755); err != nil {
		return nil, "", fmt.Errorf("prepare parent dir: %w", err)
	}
	// Assure un nom libre
	finalPath, err := uniquePath(destCanon)
	if err != nil {
		return nil, "", err
	}
	// O_EXCL pour éviter toute race d’overwrite
	f, err := os.OpenFile(finalPath, os.O_RDWR|os.O_CREATE|os.O_EXCL, perm)
	if err != nil {
		return nil, "", err
	}
	return f, finalPath, nil
}

// SafeWriteFileAtomicUnique écrit data de façon atomique, sans jamais écraser un fichier existant.
// Stratégie: écrire dans un fichier temporaire dans le même dossier puis rename vers un nom UNIQUE.
// Retourne le chemin final effectivement utilisé (peut différer si collision).
func SafeWriteFileAtomicUnique(dest string, data []byte, perm os.FileMode, d DataDirs) (string, error) {
	if err := AssertSafeTarget(dest, d); err != nil {
		return "", err
	}
	destCanon, err := canonicalize(dest)
	if err != nil {
		return "", err
	}
	parent := filepath.Dir(destCanon)
	if err := os.MkdirAll(parent, 0o755); err != nil {
		return "", fmt.Errorf("prepare parent dir: %w", err)
	}

	// Fichier temporaire
	tmp, err := os.CreateTemp(parent, ".openhvx-*")
	if err != nil {
		return "", fmt.Errorf("create temp: %w", err)
	}
	tmpPath := tmp.Name()
	defer func() {
		// Nettoyage du temp en cas d’erreur
		_ = tmp.Close()
		_ = os.Remove(tmpPath)
	}()

	// Écrire + flush
	if _, err := tmp.Write(data); err != nil {
		return "", fmt.Errorf("write temp: %w", err)
	}
	if err := tmp.Sync(); err != nil {
		return "", fmt.Errorf("sync temp: %w", err)
	}
	if err := tmp.Close(); err != nil {
		return "", fmt.Errorf("close temp: %w", err)
	}

	// Choisir un destinataire UNIQUE (pas d’overwrite)
	finalPath, err := uniquePath(destCanon)
	if err != nil {
		return "", err
	}

	// Rename atomique (même volume)
	if err := os.Rename(tmpPath, finalPath); err != nil {
		return "", fmt.Errorf("atomic rename failed: %w", err)
	}
	// Appliquer permissions (best-effort)
	_ = os.Chmod(finalPath, perm)
	return finalPath, nil
}

// SafeRenameNoOverwrite renomme/move src -> dst sans jamais écraser une cible existante.
// Si dst existe, génère un nom unique. Refuse d’opérer sur dossiers protégés.
func SafeRenameNoOverwrite(src, dst string, d DataDirs) (string, error) {
	if err := AssertSafeTarget(src, d); err != nil {
		return "", fmt.Errorf("invalid src: %w", err)
	}
	if err := AssertSafeTarget(dst, d); err != nil {
		return "", fmt.Errorf("invalid dst: %w", err)
	}
	srcCanon, err := canonicalize(src)
	if err != nil {
		return "", err
	}
	dstCanon, err := canonicalize(dst)
	if err != nil {
		return "", err
	}
	if err := os.MkdirAll(filepath.Dir(dstCanon), 0o755); err != nil {
		return "", fmt.Errorf("prepare dst parent: %w", err)
	}
	finalDst, err := uniquePath(dstCanon)
	if err != nil {
		return "", err
	}
	if err := os.Rename(srcCanon, finalDst); err != nil {
		return "", fmt.Errorf("rename failed: %w", err)
	}
	return finalDst, nil
}

// SafeCopyFileNoOverwrite copie src -> dst sans overwrite (utilise un nom unique si collision).
// ⚠️ À utiliser uniquement si Rename n’est pas possible (ex: cross-device).
func SafeCopyFileNoOverwrite(src, dst string, perm os.FileMode, d DataDirs) (string, error) {
	if err := AssertSafeTarget(src, d); err != nil {
		return "", fmt.Errorf("invalid src: %w", err)
	}
	if err := AssertSafeTarget(dst, d); err != nil {
		return "", fmt.Errorf("invalid dst: %w", err)
	}
	srcCanon, err := canonicalize(src)
	if err != nil {
		return "", err
	}
	dstCanon, err := canonicalize(dst)
	if err != nil {
		return "", err
	}
	in, err := os.Open(srcCanon)
	if err != nil {
		return "", err
	}
	defer in.Close()

	if err := os.MkdirAll(filepath.Dir(dstCanon), 0o755); err != nil {
		return "", fmt.Errorf("prepare dst parent: %w", err)
	}
	finalDst, err := uniquePath(dstCanon)
	if err != nil {
		return "", err
	}
	out, err := os.OpenFile(finalDst, os.O_RDWR|os.O_CREATE|os.O_EXCL, perm)
	if err != nil {
		return "", err
	}
	defer func() {
		_ = out.Sync()
		_ = out.Close()
	}()

	if _, err := io.Copy(out, in); err != nil {
		return "", err
	}
	if err := out.Sync(); err != nil {
		return "", err
	}
	return finalDst, nil
}

// ---------- Petits utilitaires ----------

// JoinVMDir propose un sous-dossier VM sous VMS (ex: VMS/<tenant>/<vm>), en s’assurant que ça reste sous Root.
func JoinVMDir(d DataDirs, elems ...string) (string, error) {
	path := filepath.Join(append([]string{d.VMS}, elems...)...)
	canon, err := canonicalize(path)
	if err != nil {
		return "", err
	}
	if !isUnder(canon, d.Root) {
		return "", fmt.Errorf("vm dir escapes root: %s", canon)
	}
	return canon, nil
}

// SuffixWithTenantId ajoute un suffixe "-<tenantId>" avant l’extension si présent.
func SuffixWithTenantId(p string, tenantId string) string {
	if tenantId == "" {
		return p
	}
	dir := filepath.Dir(p)
	base := filepath.Base(p)
	ext := filepath.Ext(base)
	name := strings.TrimSuffix(base, ext)
	return filepath.Join(dir, name+"-"+tenantId+ext)
}

// NextSequenceName génère "name (n).ext" à partir d’un path existant (utile pour afficher le nom retenu).
func NextSequenceName(p string) string {
	dir := filepath.Dir(p)
	base := filepath.Base(p)
	ext := filepath.Ext(base)
	name := strings.TrimSuffix(base, ext)
	for i := 1; i <= 9999; i++ {
		c := filepath.Join(dir, fmt.Sprintf("%s (%d)%s", name, i, ext))
		if _, err := os.Lstat(c); os.IsNotExist(err) {
			return c
		}
	}
	ts := time.Now().UTC().Format("20060102-150405.000")
	return filepath.Join(dir, name+"-"+ts+ext)
}

// DebugString des chemins gérés (utile pour logs)
func (d DataDirs) DebugString() string {
	return "Root=" + d.Root +
		" VMS=" + d.VMS +
		" VHD=" + d.VHD +
		" ISOs=" + d.ISOs +
		" Checkpoints=" + d.Checkpoints +
		" Logs=" + d.Logs +
		" Trash=" + d.Trash
}

// Optional helper: parse "size in MB" string to int (defensive)
func atoiDef(s string, def int) int {
	i, err := strconv.Atoi(s)
	if err != nil {
		return def
	}
	return i
}
