// Create CIDATA ISO

package main

import (
	"flag"
	"log"
	"os"

	"github.com/kdomanski/iso9660"
)

func addFile(writer *iso9660.ImageWriter, srcPath string, isoPath string) error {
	f, err := os.Open(srcPath)
	if err != nil {
		return err
	}
	defer f.Close()

	return writer.AddFile(f, isoPath)
}

func main() {
	in := flag.String("in", "", "input directory (must contain user-data, meta-data, network-config)")
	out := flag.String("out", "", "output iso path")
	label := flag.String("label", "cidata", "volume label (must be 'cidata' for cloud-init NoCloud)")
	flag.Parse()

	if *in == "" || *out == "" {
		log.Fatal("usage: cidata-iso -in <dir> -out <path.iso> [-label cidata]")
	}

	writer, err := iso9660.NewWriter()
	if err != nil {
		log.Fatal(err)
	}
	defer writer.Cleanup()

	// Ajout des fichiers obligatoires
	if err := addFile(writer, *in+"/user-data", "user-data"); err != nil {
		log.Fatal(err)
	}
	if err := addFile(writer, *in+"/meta-data", "meta-data"); err != nil {
		log.Fatal(err)
	}
	if err := addFile(writer, *in+"/network-config", "network-config"); err != nil {
		log.Fatal(err)
	}

	// Fichier de sortie
	outFile, err := os.Create(*out)
	if err != nil {
		log.Fatal(err)
	}
	defer outFile.Close()

	// Écriture finale avec le label voulu
	if err := writer.WriteTo(outFile, *label); err != nil {
		log.Fatal(err)
	}
}
