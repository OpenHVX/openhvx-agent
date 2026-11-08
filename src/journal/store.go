// Package journal owns the durable boundary before and after host effects.
// The bbolt file lock permits one executor process per journal; fsync is enabled.
package journal

import (
	"encoding/json"
	"errors"
	bolt "go.etcd.io/bbolt"
	"os"
	"path/filepath"
	"time"
)

var ErrConflict = errors.New("operation identity reused with different command")
var bucket = []byte("operations.v2")

type Record struct {
	Published bool            `json:"published"`
	ID        string          `json:"id"`
	Hash      string          `json:"hash"`
	State     string          `json:"state"` // running, uncertain, completed
	Sequence  int             `json:"sequence"`
	Result    json.RawMessage `json:"result,omitempty"`
	Recovery  json.RawMessage `json:"recovery,omitempty"` // identifiers only, no command secrets
}
type Store struct{ db *bolt.DB }

func Open(path string) (*Store, error) {
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		return nil, err
	}
	db, err := bolt.Open(path, 0600, &bolt.Options{Timeout: 2 * time.Second})
	if err != nil {
		return nil, err
	}
	s := &Store{db}
	err = db.Update(func(tx *bolt.Tx) error { _, e := tx.CreateBucketIfNotExists(bucket); return e })
	if err != nil {
		db.Close()
		return nil, err
	}
	return s, nil
}
func (s *Store) Close() error { return s.db.Close() }

// Begin commits intent before the caller may invoke an external effect.
func (s *Store) Begin(id, hash string, recovery json.RawMessage) (record Record, fresh bool, err error) {
	err = s.db.Update(func(tx *bolt.Tx) error {
		b := tx.Bucket(bucket)
		if value := b.Get([]byte(id)); value != nil {
			if e := json.Unmarshal(value, &record); e != nil {
				return e
			}
			if record.Hash != hash {
				return ErrConflict
			}
			return nil
		}
		record = Record{ID: id, Hash: hash, State: "running", Recovery: recovery}
		data, e := json.Marshal(record)
		if e != nil {
			return e
		}
		if e = b.Put([]byte(id), data); e != nil {
			return e
		}
		fresh = true
		return nil
	})
	return
}
func (s *Store) Finish(record Record) error {
	return s.db.Update(func(tx *bolt.Tx) error {
		b := tx.Bucket(bucket)
		value := b.Get([]byte(record.ID))
		if value == nil {
			return errors.New("missing journal intent")
		}
		var old Record
		if err := json.Unmarshal(value, &old); err != nil {
			return err
		}
		if old.Hash != record.Hash || record.Sequence <= old.Sequence {
			return ErrConflict
		}
		if old.State == "completed" {
			return errors.New("cannot replace a terminal result")
		}
		data, err := json.Marshal(record)
		if err != nil {
			return err
		}
		return b.Put([]byte(record.ID), data)
	})
}
func (s *Store) Uncertain() (records []Record, err error) {
	err = s.db.View(func(tx *bolt.Tx) error {
		return tx.Bucket(bucket).ForEach(func(_, value []byte) error {
			var r Record
			if e := json.Unmarshal(value, &r); e != nil {
				return e
			}
			if r.State != "completed" || !r.Published {
				records = append(records, r)
			}
			return nil
		})
	})
	return
}

// MarkPublished fences an old publisher: it cannot hide a newer observation.
func (s *Store) MarkPublished(id string, sequence int) error {
	return s.db.Update(func(tx *bolt.Tx) error {
		b := tx.Bucket(bucket)
		raw := b.Get([]byte(id))
		if raw == nil {
			return errors.New("missing published operation")
		}
		var r Record
		if err := json.Unmarshal(raw, &r); err != nil {
			return err
		}
		if r.Sequence != sequence {
			return nil
		}
		r.Published = true
		body, err := json.Marshal(r)
		if err != nil {
			return err
		}
		return b.Put([]byte(id), body)
	})
}

// A journal belongs to one logical host identity for its entire lifetime.
func (s *Store) BindAgent(agentID string) error {
	if agentID == "" {
		return errors.New("agent identity required")
	}
	return s.db.Update(func(tx *bolt.Tx) error {
		metadata, err := tx.CreateBucketIfNotExists([]byte("metadata"))
		if err != nil {
			return err
		}
		old := metadata.Get([]byte("agentId"))
		if old != nil && string(old) != agentID {
			return errors.New("journal belongs to another agent identity")
		}
		return metadata.Put([]byte("agentId"), []byte(agentID))
	})
}
