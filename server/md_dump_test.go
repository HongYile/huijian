package main

import (
	"encoding/json"
	"os"
	"testing"
)

// MD_DUMP=输入.md 时把解析结果写到 输入.json 和 输入.txt（调试用）
func TestMDDump(t *testing.T) {
	in := os.Getenv("MD_DUMP")
	if in == "" {
		t.Skip()
	}
	src, _ := os.ReadFile(in)
	atts := []Attachment{{ID: "a_1", Name: "loss.png", Mime: "image/png", Size: 1000}, {ID: "a_2", Name: "report.pdf", Mime: "application/pdf", Size: 2000}}
	d := parseMD(string(src), atts)
	b, _ := json.MarshalIndent(d, "", "  ")
	os.WriteFile(in[:len(in)-3]+".json", b, 0o644)
	os.WriteFile(in[:len(in)-3]+".txt", []byte(docPlain(d)), 0o644)
}
