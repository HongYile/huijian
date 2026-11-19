package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestDeleteAndArchiveMessages(t *testing.T) {
	dir := t.TempDir()
	st, err := OpenStore(filepath.Join(dir, "t.db"))
	if err != nil {
		t.Fatal(err)
	}
	alice, _ := st.CreateAccount("alice", "alice-pass-1")
	bob, _ := st.CreateAccount("bob", "bob-pass-12")
	ins := func(uid int64, text string, files ...Attachment) int64 {
		id, _, err := st.InsertMessage(NewMessage{UserID: uid, Topic: "t", Priority: 3, Type: "text", Text: text, Files: files})
		if err != nil {
			t.Fatal(err)
		}
		return id
	}
	m1 := ins(alice.ID, "一")
	m2 := ins(alice.ID, "二", Attachment{ID: "a1", Name: "x.txt", Mime: "text/plain", Size: 1, Sha256: "s", blob: "2026/01/01/x/x.txt"})
	m3 := ins(alice.ID, "三")
	mb := ins(bob.ID, "bob 的")

	_, cur, reset, _ := st.Changes(alice.ID, -1, 100)
	if reset {
		t.Fatal("第一次不应 reset")
	}
	if n, err := st.SetArchive(alice.ID, []int64{m1, mb}, archiveOn); err != nil || n != 1 {
		t.Fatalf("只能归档自己的消息：n=%d err=%v", n, err)
	}
	n, orphans, err := st.DeleteMessages(alice.ID, []int64{m2, mb})
	if err != nil || n != 1 || len(orphans) != 1 || orphans[0] != "2026/01/01/x/x.txt" {
		t.Fatalf("删除：n=%d orphans=%v err=%v", n, orphans, err)
	}
	ch, next, _, _ := st.Changes(alice.ID, cur, 100)
	if len(ch) != 2 || ch[0].ID != m1 || ch[0].Kind != "archive" || ch[0].State != archiveOn || ch[1].ID != m2 || ch[1].Kind != "delete" {
		t.Fatalf("变更记录不对：%+v", ch)
	}
	if again, _, _, _ := st.Changes(alice.ID, next, 100); len(again) != 0 {
		t.Fatalf("游标之后不应再有变更：%+v", again)
	}
	if bc, _, _, _ := st.Changes(bob.ID, 0, 100); len(bc) != 0 {
		t.Fatalf("bob 不应看到 alice 的变更：%+v", bc)
	}
	msgs, _ := st.Messages(alice.ID, "dev", 0, 100)
	if len(msgs) != 2 || msgs[0].ID != m1 || msgs[0].Archive != archiveOn || msgs[1].ID != m3 {
		t.Fatalf("剩余消息不对：%+v", msgs)
	}
	if bm, _ := st.Messages(bob.ID, "dev", 0, 100); len(bm) != 1 {
		t.Fatal("bob 的消息不应被删除")
	}

	// 对账：只返回自己的消息和归档状态，游标与变更记录一致
	items, snext, err := st.MessageStates(alice.ID)
	if err != nil || len(items) != 2 || items[0] != [2]int64{m1, archiveOn} || items[1] != [2]int64{m3, archiveAuto} || snext != next {
		t.Fatalf("对账结果不对：%v next=%d/%d err=%v", items, snext, next, err)
	}

	// 变更记录被清理后：早于保留范围的游标要 reset，游标不会退回 0
	st.db.Exec(`DELETE FROM msg_changes`)
	if _, n2, r2, _ := st.Changes(alice.ID, next, 100); r2 || n2 != next {
		t.Fatalf("游标正好在最新处时不应 reset：next=%d reset=%v", n2, r2)
	}
	if _, n2, r2, _ := st.Changes(alice.ID, cur, 100); !r2 || n2 != next {
		t.Fatalf("错过了已清理的变更应 reset：next=%d reset=%v", n2, r2)
	}
	if _, _, r2, _ := st.Changes(alice.ID, next+50, 100); !r2 {
		t.Fatal("游标超过服务端记录（数据库从备份恢复）应 reset")
	}

	// 删除附件文件后，附件自己的目录一起删掉；年/月/日目录保留（可能正有新上传在里面建目录）
	root := filepath.Join(dir, "files")
	p := filepath.Join(root, "2026/01/01/x/x.txt")
	os.MkdirAll(filepath.Dir(p), 0o750)
	os.WriteFile(p, []byte("x"), 0o640)
	os.WriteFile(filepath.Join(root, "2026", "keep.txt"), []byte("k"), 0o640)
	fst := &fileStore{files: &dirGuard{dir: root}, local: root, legacy: root}
	fst.remove([]string{"2026/01/01/x/x.txt", "../escape"})
	if _, err := os.Stat(filepath.Join(root, "2026/01/01/x")); !os.IsNotExist(err) {
		t.Fatal("附件自己的目录应被删除")
	}
	if _, err := os.Stat(filepath.Join(root, "2026/01/01")); err != nil {
		t.Fatal("日期目录应保留")
	}
	if st.ChangesEpoch() == "" {
		t.Fatal("应生成变更纪元")
	}
	if _, err := os.Stat(filepath.Join(root, "2026", "keep.txt")); err != nil {
		t.Fatal("非空目录不应被删除")
	}
}

// 从备份恢复后换一个变更纪元，客户端据此重新对账
func TestRestoreRotatesChangesEpoch(t *testing.T) {
	src := t.TempDir()
	st, err := OpenStore(filepath.Join(src, "huijian.db"))
	if err != nil {
		t.Fatal(err)
	}
	u, _ := st.CreateAccount("alice", "alice-pass-1")
	st.InsertMessage(NewMessage{UserID: u.ID, Topic: "t", Priority: 3, Type: "text", Text: "x"})
	old := st.ChangesEpoch()
	backup := t.TempDir()
	os.MkdirAll(filepath.Join(backup, "db"), 0o750)
	if _, err := st.db.Exec(`VACUUM INTO ?`, filepath.Join(backup, "db", "huijian-20260101-000000.db")); err != nil {
		t.Fatal(err)
	}
	st.db.Close()
	data := t.TempDir()
	t.Setenv("HUIJIAN_DATA", data)
	t.Setenv("HUIJIAN_PUBLIC_ADDR", "127.0.0.1:1")
	if rc := runRestore([]string{"-y", backup}); rc != 0 {
		t.Fatalf("恢复失败 rc=%d", rc)
	}
	st2, err := OpenStore(filepath.Join(data, "huijian.db"))
	if err != nil {
		t.Fatal(err)
	}
	if e := st2.ChangesEpoch(); e == "" || e == old {
		t.Fatalf("恢复后纪元应更换：%q → %q", old, e)
	}
}
