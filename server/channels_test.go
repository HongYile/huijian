package main

import (
	"path/filepath"
	"testing"
)

func TestChannelSettings(t *testing.T) {
	st, err := OpenStore(filepath.Join(t.TempDir(), "t.db"))
	if err != nil {
		t.Fatal(err)
	}
	alice, _ := st.CreateAccount("alice", "alice-pass-1")
	bob, _ := st.CreateAccount("bob", "bob-pass-12")
	_, cur, _, _ := st.Changes(alice.ID, -1, 100)
	yes, alias := true, "训练"
	c, err := st.UpdateChannel(alice.ID, channelPatch{Topic: "train", Alias: &alias, Muted: &yes})
	if err != nil || c.Alias != "训练" || !c.Muted || c.Hidden || c.Pinned {
		t.Fatalf("改名 + 静音：%+v %v", c, err)
	}
	c, _ = st.UpdateChannel(alice.ID, channelPatch{Topic: "train", Pinned: &yes})
	if c.Alias != "训练" || !c.Muted || !c.Pinned {
		t.Fatalf("只改置顶时其他设置应保留：%+v", c)
	}
	st.UpdateChannel(alice.ID, channelPatch{Topic: "logs", Hidden: &yes})
	if err := st.SetChannelOrder(alice.ID, []string{"infra", "train", "infra"}); err != nil {
		t.Fatal(err)
	}
	cs, _ := st.Channels(alice.ID)
	got := map[string]Channel{}
	for _, c := range cs {
		got[c.Topic] = c
	}
	if len(cs) != 3 || got["infra"].Sort != 1 || got["train"].Sort != 2 || got["logs"].Sort != 0 || !got["logs"].Hidden {
		t.Fatalf("排序 / 隐藏不对：%+v", cs)
	}
	if b, _ := st.Channels(bob.ID); len(b) != 0 {
		t.Fatal("bob 不应看到 alice 的频道设置")
	}
	hidden, muted := st.channelFlags(alice.ID)
	if !hidden["logs"] || !muted["train"] || hidden["train"] {
		t.Fatalf("静默标记用的设置不对：%v %v", hidden, muted)
	}
	ch, _, _, _ := st.Changes(alice.ID, cur, 100)
	if len(ch) != 4 || ch[0].Kind != "channels" {
		t.Fatalf("每次修改都应写一条 channels 变更：%+v", ch)
	}
	st.SetChannelOrder(alice.ID, nil)
	cs, _ = st.Channels(alice.ID)
	for _, c := range cs {
		if c.Sort != 0 {
			t.Fatalf("恢复自动排序后不应有手动顺序：%+v", cs)
		}
	}
	st.deleteChannelSettings(alice.ID, "train")
	if cs, _ := st.Channels(alice.ID); len(cs) != 2 {
		t.Fatalf("删除频道设置：%+v", cs)
	}
}
