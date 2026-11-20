package main

// CreateAccount：测试用——建一个用旧方式（密码哈希）登录、还没有加密钥匙的账号，相当于 0.9 以前的旧账号。
// 正式代码里没有不带钥匙的建号路径：0.9.0 起账号只能注册产生（Store.Register）
func (s *Store) CreateAccount(username, password string) (*Account, error) {
	if err := checkCredentials(username, password); err != nil {
		return nil, err
	}
	return s.createAccount(username, hashPassword(password), "", "", "")
}

func (s *Store) createAccount(username, passHash, authSalt, authHashV, invite string) (*Account, error) {
	username = normUsername(username)
	tx, err := s.db.Begin()
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()
	if invite != "" {
		if err := consumeInvite(tx, invite); err != nil {
			return nil, err
		}
	}
	res, err := tx.Exec(`INSERT INTO users(name,created_at,username,username_key,pass_hash,auth_salt,auth_hash) VALUES(?,?,?,?,?,?,?)`,
		"u_"+randHex(8), now(), username, usernameKey(username), passHash, authSalt, authHashV)
	if isUniqueErr(err) {
		return nil, errUsernameTaken
	}
	if err != nil {
		return nil, err
	}
	id, _ := res.LastInsertId()
	if invite != "" {
		if err := recordInvite(tx, invite, id, username); err != nil {
			return nil, err
		}
	}
	// 不自动生成 pushkey：用户自己新建（客户端新建第一把时名字默认填 default）
	if err := bumpStats(tx, 0, 0, 1); err != nil {
		return nil, err
	}
	if err := tx.Commit(); err != nil {
		return nil, err
	}
	return s.AccountByID(id)
}
