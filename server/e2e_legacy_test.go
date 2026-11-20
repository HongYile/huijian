package main

import (
	"bytes"
	"strconv"
	"strings"
	"time"
)

// legacyPlain：模拟 0.9.0 以前存下的明文历史（账号还没有钥匙时收到的消息）。
// 0.9.0 起推送接口不再收明文，补加密相关的测试用它直接写库：附件和推送时一样经 saveTemp + files.save 落盘
// （按内容去重、目录名用标题），字段默认值和 handlePush 一致。返回消息 id
func (e *e2eEnv) legacyPlain(pushkey string, fields map[string]string, files map[string][]byte, order ...string) int64 {
	e.t.Helper()
	pk, err := e.h.st.PushkeyByKey(pushkey)
	if err != nil {
		e.t.Fatal(err)
	}
	var ups []*upFile
	var names []string
	for _, name := range order {
		uf, err := e.h.saveTemp(bytes.NewReader(files[name]), cleanName(name), "")
		if err != nil {
			e.t.Fatal(err)
		}
		ups = append(ups, uf)
		names = append(names, uf.name)
	}
	defer removeTemps(ups)
	text := fields["text"]
	if text == "" {
		text = "📎 " + strings.Join(names, "、")
	}
	typ := fields["type"]
	if typ == "" {
		typ = "markdown"
	}
	prio := 3
	if p := fields["priority"]; p != "" {
		prio, _ = strconv.Atoi(p)
	}
	topic := fields["topic"]
	if topic == "" {
		topic = "default"
	}
	m := NewMessage{UserID: pk.UserID, PushkeyID: pk.ID, Topic: topic, Thread: fields["thread"], Priority: prio,
		Type: typ, Text: text, Desp: fields["desp"], Source: pk.Name, Idem: fields["idem"]}
	if len(ups) > 0 {
		rels, err := e.h.files.save(ups, text, time.Now())
		if err != nil {
			e.t.Fatal(err)
		}
		for i, f := range ups {
			m.Files = append(m.Files, Attachment{Name: f.name, Mime: f.mime, Size: f.size, Sha256: f.sha256, blob: rels[i]})
		}
	}
	id, _, err := e.h.st.InsertMessage(m)
	if err != nil {
		e.t.Fatal(err)
	}
	return id
}
