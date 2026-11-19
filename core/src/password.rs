//! 开启加密、注册、改密码时的密码强度检查。服务器拿不到密码，只能由客户端检查；放在共用核心里，各端判断完全一致。
//! 目标是挡住「数据库被偷后几分钟就能离线猜中」的密码，不追求复杂度规则（不强制大小写、符号）。

/// 不合格时返回原因（中文，直接显示给用户）
pub fn check(password: &str, username: &str) -> Option<&'static str> {
    let chars: Vec<char> = password.chars().collect();
    if chars.len() < 10 {
        return Some("密码至少 10 位");
    }
    let lower = password.to_lowercase();
    let mut distinct = chars.clone();
    distinct.sort_unstable();
    distinct.dedup();
    if distinct.len() <= 3 {
        return Some("重复的字符太多，换一个更随机的密码");
    }
    if is_repeat(&chars) {
        return Some("重复的片段太简单，换一个更随机的密码");
    }
    if is_sequence(&lower) {
        return Some("连续的字母或数字太容易猜到");
    }
    if is_keyboard(&lower) {
        return Some("键盘上连着按的密码太容易猜到");
    }
    let user = username.trim().to_lowercase();
    if user.chars().count() >= 3 && lower.contains(&user) {
        return Some("密码不能包含用户名");
    }
    let core = strip_affixes(&lower);
    if COMMON.iter().any(|c| *c == lower || *c == core) {
        return Some("这是常见密码，很容易被猜到");
    }
    None
}

/// 整个密码由一个不超过一半长度的片段重复组成，例如 abcabcabcabc、1212121212
fn is_repeat(c: &[char]) -> bool {
    (1..=c.len() / 2).any(|n| c.len() % n == 0 && c.chunks(n).all(|x| x == &c[..n]))
}

/// 每一位都比前一位大 1 或小 1（abcdefghij、9876543210）
fn is_sequence(s: &str) -> bool {
    let b: Vec<u32> = s.chars().map(|c| c as u32).collect();
    let up = b.windows(2).all(|w| w[1] == w[0] + 1);
    let down = b.windows(2).all(|w| w[0] == w[1] + 1);
    let digits_wrap = s.chars().all(|c| c.is_ascii_digit()) && "12345678901234567890".contains(s);
    up || down || digits_wrap || "09876543210987654321".contains(s)
}

/// 整个密码是键盘上一行或一列连着按出来的
fn is_keyboard(s: &str) -> bool {
    const ROWS: &[&str] = &[
        "`1234567890-=", "qwertyuiop[]\\", "asdfghjkl;'", "zxcvbnm,./",
        "1qaz2wsx3edc4rfv5tgb6yhn7ujm8ik,9ol.0p;/", "qazwsxedcrfvtgbyhnujmikolp",
        "1q2w3e4r5t6y7u8i9o0p", "q1w2e3r4t5y6u7i8o9p0", "zaq12wsxcde34rfvbgt56yhnmju78ik,.lo90p;/",
    ];
    let rev: String = s.chars().rev().collect();
    ROWS.iter().any(|r| {
        let doubled = format!("{r}{r}");
        doubled.contains(s) || doubled.contains(rev.as_str())
    })
}

/// 去掉常见的前后缀（数字、符号）后的主体：password2024!、!qwerty123456
fn strip_affixes(s: &str) -> String {
    s.trim_matches(|c: char| c.is_ascii_digit() || c.is_ascii_punctuation()).to_string()
}

/// 常见密码（小写；包括 10 位以上的高频密码和去掉数字后缀的主体）
const COMMON: &[&str] = &[
    "password", "passw0rd", "p@ssw0rd", "p@ssword", "pass", "passwd", "password1", "mypassword", "yourpassword", "newpassword",
    "qwerty", "qwertyuiop", "qwerty123", "asdfghjkl", "zxcvbnm", "1qaz2wsx", "1q2w3e4r", "1q2w3e4r5t", "1qaz2wsx3edc", "qazwsxedc",
    "iloveyou", "iloveyou1", "loveyou", "woaini", "woaini1314", "woaini520", "520520", "5201314", "1314520", "1314521",
    "admin", "administrator", "root", "toor", "letmein", "welcome", "welcome1", "changeme", "default", "guest",
    "abc", "abcd", "abc123", "abcd1234", "abcdef", "abcdefg", "abcdefgh", "a1b2c3", "a1b2c3d4", "aa123456",
    "dragon", "monkey", "football", "baseball", "basketball", "soccer", "superman", "batman", "spiderman", "starwars",
    "princess", "sunshine", "shadow", "master", "michael", "jennifer", "jordan", "charlie", "freedom", "whatever",
    "trustno1", "hello", "helloworld", "hellokitty", "computer", "internet", "samsung", "iphone", "android", "google",
    "football1", "liverpool", "chelsea", "arsenal", "manchester", "michelle", "jessica", "daniel", "anthony", "ashley",
    "zhang", "wang", "li", "liu", "chen", "yang", "huang", "zhao", "zhou", "wu",
    "huijian", "hongyan", "pushdeer", "bark", "secret", "security", "mima", "mimamima", "wodemima", "zhangsan",
    "lisi", "wangwu", "123qwe", "qwe123", "asd123", "zxc123", "qweasdzxc", "qweasd", "asdasd", "zxczxc",
    "aaaaaa", "111111", "000000", "123123", "121212", "123321", "654321", "666666", "888888", "987654",
    "1234567890", "12345678910", "0123456789", "0987654321", "1122334455", "1234554321", "1029384756", "1357924680", "2468013579", "1111122222",
    "11223344", "12341234", "123456abc", "abc123456", "a123456789", "qq123456", "qq123456789", "woshishei", "nihao", "nihao123",
    "summer", "winter", "spring", "autumn", "flower", "lovely", "family", "forever", "beautiful", "angel",
];

#[cfg(test)]
mod tests {
    use super::check;

    #[test]
    fn rules() {
        for (pw, bad) in [
            ("short1!", true),
            ("aaaaaaaaaaaa", true),
            ("abcabcabcabc", true),
            ("1212121212", true),
            ("abcdefghijk", true),
            ("9876543210", true),
            ("qwertyuiop", true),
            ("1qaz2wsx3edc", true),
            ("asdfghjkl;'", true),
            ("password2024!", true),
            ("Woaini1314520", true), // 去掉数字后是常见的 woaini
            ("alice-secret-99", true),  // 含用户名
            ("correct horse battery", false),
            ("Tq7#mZ2!pL9x", false),
            ("回笺是一个推送服务呀", false),
        ] {
            assert_eq!(check(pw, "alice").is_some(), bad, "{pw}: {:?}", check(pw, "alice"));
        }
        assert!(check("woaini1314", "").is_some());
        assert!(check("12345678901", "").is_some());
    }
}
