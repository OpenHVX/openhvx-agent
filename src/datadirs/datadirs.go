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
	Images      string // GLOBAL, lecture seule (catalogue d’images cloud)
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
		Images:      filepath.Join(root, "Images"),
		ISOs:        filepath.Join(root, "ISOs"),
		Checkpoints: filepath.Join(root, "Checkpoints"),
		Logs:        filepath.Join(root, "Logs"),
		Trash:       filepath.Join(root, "_trash"),
	}

	for _, p := range []string{d.Root, d.VMS, d.VHD, d.Images, d.ISOs, d.Checkpoints, d.Logs, d.Trash} {
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
	for _, dir := range []string{d.Root, d.VMS, d.VHD, d.Images, d.ISOs, d.Checkpoints, d.Logs, d.Trash} {
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
		filepath.Clean(d.Images):      {},
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
		}
		return "", false
	}

	if cand, ok := try(p); ok {
		return cand, nil
	}

	for i := 1; i <= 9999; i++ {
		c := filepath.Join(dir, fmt.Sprintf("%s (%d)%s", name, i, ext))
		if cand, ok := try(c); ok {
			return cand, nil
		}
	}

	ts := time.Now().UTC().Format("20060102-150405.000")
	c := filepath.Join(dir, fmt.Sprintf("%s-%s%s", name, ts, ext))
	if cand, ok := try(c); ok {
		return cand, nil
	}
	return "", fmt.Errorf("unable to find a free name for %s", p)
}

func SafeMkdirAll(dir string, mode os.FileMode, d DataDirs) error {
	canon, err := canonicalize(dir)
	if err != nil {
		return err
	}
	if !isUnder(canon, d.Root) {
		return fmt.Errorf("mkdir outside managed root: %s", canon)
	}
	if IsProtectedPath(canon, d) {
		return fmt.Errorf("refuse to mkdir a protected dir: %s", canon)
	}
	return os.MkdirAll(canon, mode)
}

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
	finalPath, err := uniquePath(destCanon)
	if err != nil {
		return nil, "", err
	}
	f, err := os.OpenFile(finalPath, os.O_RDWR|os.O_CREATE|os.O_EXCL, perm)
	if err != nil {
		return nil, "", err
	}
	return f, finalPath, nil
}

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

	tmp, err := os.CreateTemp(parent, ".openhvx-*")
	if err != nil {
		return "", fmt.Errorf("create temp: %w", err)
	}
	tmpPath := tmp.Name()
	defer func() {
		_ = tmp.Close()
		_ = os.Remove(tmpPath)
	}()

	if _, err := tmp.Write(data); err != nil {
		return "", fmt.Errorf("write temp: %w", err)
	}
	if err := tmp.Sync(); err != nil {
		return "", fmt.Errorf("sync temp: %w", err)
	}
	if err := tmp.Close(); err != nil {
		return "", fmt.Errorf("close temp: %w", err)
	}

	finalPath, err := uniquePath(destCanon)
	if err != nil {
		return "", err
	}
	if err := os.Rename(tmpPath, finalPath); err != nil {
		return "", fmt.Errorf("atomic rename failed: %w", err)
	}
	_ = os.Chmod(finalPath, perm)
	return finalPath, nil
}

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

// JoinTenantVMDir construit VMS/<tenantId>/<...>
func JoinTenantVMDir(d DataDirs, tenantId string, elems ...string) (string, error) {
	if tenantId == "" {
		return "", fmt.Errorf("empty tenantId")
	}
	parts := append([]string{d.VMS, tenantId}, elems...)
	p := filepath.Join(parts...)
	canon, err := canonicalize(p)
	if err != nil {
		return "", err
	}
	if !isUnder(canon, d.VMS) {
		return "", fmt.Errorf("vm dir escapes VMS: %s", canon)
	}
	return canon, nil
}

// JoinImagesPath construit un chemin SOUS le dépôt global d'images.
func JoinImagesPath(d DataDirs, elems ...string) (string, error) {
	p := filepath.Join(append([]string{d.Images}, elems...)...)
	canon, err := canonicalize(p)
	if err != nil {
		return "", err
	}
	if !isUnder(canon, d.Images) {
		return "", fmt.Errorf("image path escapes Images: %s", canon)
	}
	return canon, nil
}

// AssertReadableImage s'assure qu'un chemin d'image est bien sous d.Images.
func AssertReadableImage(imgPath string, d DataDirs) error {
	c, err := canonicalize(imgPath)
	if err != nil {
		return err
	}
	if !isUnder(c, d.Images) {
		return fmt.Errorf("image not under Images: %s", c)
	}
	return nil
}

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

func (d DataDirs) DebugString() string {
	return "Root=" + d.Root +
		" VMS=" + d.VMS +
		" VHD=" + d.VHD +
		" Images=" + d.Images +
		" ISOs=" + d.ISOs +
		" Checkpoints=" + d.Checkpoints +
		" Logs=" + d.Logs +
		" Trash=" + d.Trash
}

func atoiDef(s string, def int) int {
	i, err := strconv.Atoi(s)
	if err != nil {
		return def
	}
	return i
}
