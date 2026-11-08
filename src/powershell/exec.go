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

// RunActionScript exécute powershell/actions/<action>.ps1.
//
// - Passe les "data" (map) en JSON via l'argument nommé: -InputJson '<json>'.
// - En parallèle, envoie sur STDIN un wrapper { "action": "<action>", "data": {...} } pour compatibilité.
// - Never rerun a script based on stderr: an error may follow a host effect.
func RunActionScript(action string, data map[string]any) ([]byte, error) {
	ps, err := findPwsh()
	if err != nil {
		return nil, err
	}

	scriptPath, err := resolveActionScript(action)
	if err != nil {
		return nil, err
	}

	// JSON des "data" (pour -InputJson)
	dataOnlyJSON, _ := json.Marshal(data)

	// Payload STDIN compat: { action, data }
	task := map[string]any{"action": action, "data": data}
	stdinPayload, _ := json.Marshal(task)

	// Tentative 1: avec -InputJson
	args := []string{"-ExecutionPolicy", "Bypass", "-NoProfile", "-File", scriptPath, "-InputJson", string(dataOnlyJSON)}
	out, stderr, runErr := runPwsh(ps, args, stdinPayload)
	if runErr == nil {
		return out, nil
	}

	// Echec 1 "classique"
	if len(out) > 0 {
		if len(stderr) > 0 {
			return out, errors.New("action script failed: " + strings.TrimSpace(string(stderr)))
		}
		return out, errors.New("action script failed")
	}
	return nil, errors.New("action script failed: " + strings.TrimSpace(string(stderr)))

}

func runPwsh(ps string, args []string, stdin []byte) ([]byte, []byte, error) {
	cmd := exec.Command(ps, args...)
	if len(stdin) > 0 {
		cmd.Stdin = bytes.NewReader(stdin)
	}

	var out, stderr bytes.Buffer
	cmd.Stdout = &out
	cmd.Stderr = &stderr

	err := cmd.Run()
	if err != nil {
		// On renvoie quand même stdout/stderr pour analyse
		return out.Bytes(), stderr.Bytes(), err
	}
	if out.Len() == 0 {
		return nil, nil, errors.New("empty action output")
	}
	return out.Bytes(), stderr.Bytes(), nil
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
