// 网页内核里的界面文案（查找条、图片占位）。外壳的文案在 Nib/*.lproj。
// 界面语言由外壳在 __nibSettings.lang 里给出（Bundle 选中的本地化，如 zh-Hans、ja），启动后不变。
// 键是 CodeMirror 的 phrase 原文（英文），没翻译的键直接显示英文。

const TABLES = {
  'zh-Hans': {
    Find: '查找', Replace: '替换', next: '下一个', previous: '上一个', all: '全部',
    'match case': '区分大小写', regexp: '正则', 'by word': '全词', replace: '替换', 'replace all': '全部替换',
    close: '关闭', Done: '完成', 'No results': '无结果', '$1 of $2': '$1/$2', 'current match': '当前匹配',
    'on line': '在第', 'replaced $ matches': '已替换 $ 处', 'replaced match on line $': '已替换第 $ 行的匹配',
    'Image unavailable: ': '图片无法显示：',
  },
  'zh-Hant': {
    Find: '尋找', Replace: '取代', next: '下一個', previous: '上一個', all: '全部',
    'match case': '區分大小寫', regexp: '正規表示式', 'by word': '全字', replace: '取代', 'replace all': '全部取代',
    close: '關閉', Done: '完成', 'No results': '沒有結果', '$1 of $2': '$1/$2', 'current match': '目前相符項目',
    'on line': '在第', 'replaced $ matches': '已取代 $ 處', 'replaced match on line $': '已取代第 $ 行的相符項目',
    'Image unavailable: ': '無法顯示圖片：',
  },
  ja: {
    Find: '検索', Replace: '置換', next: '次へ', previous: '前へ', all: 'すべて',
    'match case': '大文字と小文字を区別', regexp: '正規表現', 'by word': '単語単位', replace: '置換', 'replace all': 'すべて置換',
    close: '閉じる', Done: '完了', 'No results': '一致なし', '$1 of $2': '$1/$2', 'current match': '現在の一致',
    'on line': '行', 'replaced $ matches': '$ 件を置換しました', 'replaced match on line $': '$ 行目の一致を置換しました',
    'Image unavailable: ': '画像を表示できません：',
  },
  ko: {
    Find: '찾기', Replace: '대치', next: '다음', previous: '이전', all: '모두',
    'match case': '대소문자 구분', regexp: '정규 표현식', 'by word': '단어 단위', replace: '대치', 'replace all': '모두 대치',
    close: '닫기', Done: '완료', 'No results': '결과 없음', '$1 of $2': '$1/$2', 'current match': '현재 일치 항목',
    'on line': '줄', 'replaced $ matches': '$개 항목을 대치함', 'replaced match on line $': '$번째 줄의 일치 항목을 대치함',
    'Image unavailable: ': '이미지를 표시할 수 없음: ',
  },
  de: {
    Find: 'Suchen', Replace: 'Ersetzen', next: 'Weiter', previous: 'Zurück', all: 'Alle',
    'match case': 'Groß-/Kleinschreibung beachten', regexp: 'Regulärer Ausdruck', 'by word': 'Ganzes Wort', replace: 'Ersetzen', 'replace all': 'Alle ersetzen',
    close: 'Schließen', Done: 'Fertig', 'No results': 'Keine Treffer', '$1 of $2': '$1 von $2', 'current match': 'Aktueller Treffer',
    'on line': 'in Zeile', 'replaced $ matches': '$ Treffer ersetzt', 'replaced match on line $': 'Treffer in Zeile $ ersetzt',
    'Image unavailable: ': 'Bild nicht verfügbar: ',
  },
  fr: {
    Find: 'Rechercher', Replace: 'Remplacer', next: 'Suivant', previous: 'Précédent', all: 'Tout',
    'match case': 'Respecter la casse', regexp: 'Expression régulière', 'by word': 'Mot entier', replace: 'Remplacer', 'replace all': 'Tout remplacer',
    close: 'Fermer', Done: 'Terminé', 'No results': 'Aucun résultat', '$1 of $2': '$1 sur $2', 'current match': 'Occurrence actuelle',
    'on line': 'à la ligne', 'replaced $ matches': '$ occurrences remplacées', 'replaced match on line $': 'Occurrence remplacée à la ligne $',
    'Image unavailable: ': 'Image indisponible : ',
  },
  es: {
    Find: 'Buscar', Replace: 'Reemplazar', next: 'Siguiente', previous: 'Anterior', all: 'Todo',
    'match case': 'Coincidir mayúsculas', regexp: 'Expresión regular', 'by word': 'Palabra completa', replace: 'Reemplazar', 'replace all': 'Reemplazar todo',
    close: 'Cerrar', Done: 'OK', 'No results': 'Sin resultados', '$1 of $2': '$1 de $2', 'current match': 'Coincidencia actual',
    'on line': 'en la línea', 'replaced $ matches': '$ coincidencias reemplazadas', 'replaced match on line $': 'Coincidencia reemplazada en la línea $',
    'Image unavailable: ': 'Imagen no disponible: ',
  },
}

function pick(lang) {
  if (TABLES[lang]) return TABLES[lang]
  // zh-HK、zh-TW 之类按书写系统归到繁体，其余中文归简体；其他语言取主语言码
  if (/^zh-(Hant|HK|TW|MO)/i.test(lang)) return TABLES['zh-Hant']
  if (/^zh/i.test(lang)) return TABLES['zh-Hans']
  return TABLES[lang.split('-')[0]] || {}
}

/** 当前界面语言的文案表，可直接交给 EditorState.phrases。 */
export const phrases = pick(window.__nibSettings?.lang || 'en')

/** 取一条文案；没有翻译时用英文原文。 */
export const t = (key) => phrases[key] ?? key
