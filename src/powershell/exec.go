package powershell

import (
	"bytes"
	"encoding/json"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"strings"
)

// RunActionScript exécute powershell/actions/<action>.ps1 en passant le task JSON sur STDIN.
// action : ex. "vm.power", "inventory.refresh"
func RunActionScript(action string, data map[string]any) ([]byte, error) {
	ps, err := findPwsh()
	if err != nil {
		return nil, err
	}

	scriptPath, err := resolveActionScript(action)
	if err != nil {
		return nil, err
	}

	task := map[string]any{"action": action, "data": data}
	payload, _ := json.Marshal(task)

	cmd := exec.Command(ps, "-ExecutionPolicy", "Bypass", "-NoProfile", "-File", scriptPath)
	cmd.Stdin = bytes.NewReader(payload)

	var out, stderr bytes.Buffer
	cmd.Stdout = &out
	cmd.Stderr = &stderr

	if err := cmd.Run(); err != nil {
		if out.Len() > 0 {
			// garder le JSON du script même si exit 1
			return out.Bytes(), errors.New("action script failed")
		}
		return nil, errors.New("action script failed: " + strings.TrimSpace(stderr.String()))
	}
	if out.Len() == 0 {
		return nil, errors.New("empty action output")
	}
	return out.Bytes(), nil
}

func resolveActionScript(action string) (string, error) {
	// Sécurise le nom de fichier: lettres, chiffres, ., -, _
	safe := strings.ToLower(action)
	re := regexp.MustCompile(`[^a-z0-9._-]`)
	safe = re.ReplaceAllString(safe, "-")
	rel := filepath.Join("powershell", "actions", safe+".ps1")
	return resolveScript(rel)
}

// --- Helpers réutilisables ---

func findPwsh() (string, error) {
	// Préfère pwsh (PowerShell 7+)
	if p, err := exec.LookPath("pwsh"); err == nil {
		return p, nil
	}
	// Windows: powershell.exe
	if runtime.GOOS == "windows" {
		if p, err := exec.LookPath("powershell.exe"); err == nil {
			return p, nil
		}
	}
	// Linux/macOS: powershell
	if p, err := exec.LookPath("powershell"); err == nil {
		return p, nil
	}
	return "", errors.New("neither 'pwsh' nor 'powershell' found in PATH")
}

func resolveScript(rel string) (string, error) {
	// 1) à côté du binaire
	if exe, err := os.Executable(); err == nil {
		base := filepath.Dir(exe)
		full := filepath.Join(base, rel)
		if _, err := os.Stat(full); err == nil {
			return full, nil
		}
	}
	// 2) dossier courant (dev: go run .)
	if wd, err := os.Getwd(); err == nil {
		alt := filepath.Join(wd, rel)
		if _, err := os.Stat(alt); err == nil {
			return alt, nil
		}
	}
	return "", errors.New("script not found: " + rel)
}
