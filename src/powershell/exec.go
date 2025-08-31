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
// - Si le script ne connaît pas -InputJson, on retente automatiquement sans ce paramètre.
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

	// Si l'erreur mentionne un paramètre inconnu (-InputJson), on retente sans
	if isUnknownParamError(stderr, "InputJson") {
		args2 := []string{"-ExecutionPolicy", "Bypass", "-NoProfile", "-File", scriptPath}
		out2, stderr2, runErr2 := runPwsh(ps, args2, stdinPayload)
		if runErr2 == nil {
			return out2, nil
		}
		// Echec 2: si le script a tout de même produit un JSON utile, on le renvoie avec une erreur générique
		if len(out2) > 0 {
			return out2, errors.New("action script failed")
		}
		return nil, errors.New("action script failed: " + strings.TrimSpace(string(stderr2)))
	}

	// Echec 1 "classique"
	if len(out) > 0 {
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

func isUnknownParamError(stderr []byte, param string) bool {
	// Exemples de messages:
	// "A parameter cannot be found that matches parameter name 'InputJson'."
	// "Un paramètre ne peut pas être trouvé qui correspond au nom du paramètre « InputJson »."
	s := strings.ToLower(string(stderr))
	return strings.Contains(s, "parameter cannot be found") &&
		strings.Contains(s, strings.ToLower(param))
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
