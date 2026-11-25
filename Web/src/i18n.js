// UI strings for the web core (find bar, image placeholder). The shell's strings live in Nib/*.lproj.
// The UI language is provided by the shell in __nibSettings.lang (the localisation the Bundle selected, e.g. zh-Hans, ja) and does not change after launch.
// Keys are CodeMirror's original English phrases; keys without a translation are shown in English.

const TABLES = {
  'zh-Hans': {
    Find: '查找', Replace: '替换', next: '下一个', previous: '上一个', all: '全部',
    'match case': '区分大小写', regexp: '正则', 'by word': '全词', replace: '替换', 'replace all': '全部替换',
    close: '关闭', Done: '完成', 'No results': '无结果', '$1 of $2': '$1/$2', 'current match': '当前匹配',
    'on line': '在第', 'replaced $ matches': '已替换 $ 处', 'replaced match on line $': '已替换第 $ 行的匹配',
    'Image unavailable: ': '图片无法显示：',
    'Diagram could not be rendered: ': '图表无法渲染：',
  },
  'zh-Hant': {
    Find: '尋找', Replace: '取代', next: '下一個', previous: '上一個', all: '全部',
    'match case': '區分大小寫', regexp: '正規表示式', 'by word': '全字', replace: '取代', 'replace all': '全部取代',
    close: '關閉', Done: '完成', 'No results': '沒有結果', '$1 of $2': '$1/$2', 'current match': '目前相符項目',
    'on line': '在第', 'replaced $ matches': '已取代 $ 處', 'replaced match on line $': '已取代第 $ 行的相符項目',
    'Image unavailable: ': '無法顯示圖片：',
    'Diagram could not be rendered: ': '無法繪製圖表：',
  },
  ja: {
    Find: '検索', Replace: '置換', next: '次へ', previous: '前へ', all: 'すべて',
    'match case': '大文字と小文字を区別', regexp: '正規表現', 'by word': '単語単位', replace: '置換', 'replace all': 'すべて置換',
    close: '閉じる', Done: '完了', 'No results': '一致なし', '$1 of $2': '$1/$2', 'current match': '現在の一致',
    'on line': '行', 'replaced $ matches': '$ 件を置換しました', 'replaced match on line $': '$ 行目の一致を置換しました',
    'Image unavailable: ': '画像を表示できません：',
    'Diagram could not be rendered: ': '図を描画できません：',
  },
  ko: {
    Find: '찾기', Replace: '대치', next: '다음', previous: '이전', all: '모두',
    'match case': '대소문자 구분', regexp: '정규 표현식', 'by word': '단어 단위', replace: '대치', 'replace all': '모두 대치',
    close: '닫기', Done: '완료', 'No results': '결과 없음', '$1 of $2': '$1/$2', 'current match': '현재 일치 항목',
    'on line': '줄', 'replaced $ matches': '$개 항목을 대치함', 'replaced match on line $': '$번째 줄의 일치 항목을 대치함',
    'Image unavailable: ': '이미지를 표시할 수 없음: ',
    'Diagram could not be rendered: ': '다이어그램을 렌더링할 수 없음: ',
  },
  de: {
    Find: 'Suchen', Replace: 'Ersetzen', next: 'Weiter', previous: 'Zurück', all: 'Alle',
    'match case': 'Groß-/Kleinschreibung beachten', regexp: 'Regulärer Ausdruck', 'by word': 'Ganzes Wort', replace: 'Ersetzen', 'replace all': 'Alle ersetzen',
    close: 'Schließen', Done: 'Fertig', 'No results': 'Keine Treffer', '$1 of $2': '$1 von $2', 'current match': 'Aktueller Treffer',
    'on line': 'in Zeile', 'replaced $ matches': '$ Treffer ersetzt', 'replaced match on line $': 'Treffer in Zeile $ ersetzt',
    'Image unavailable: ': 'Bild nicht verfügbar: ',
    'Diagram could not be rendered: ': 'Diagramm kann nicht dargestellt werden: ',
  },
  fr: {
    Find: 'Rechercher', Replace: 'Remplacer', next: 'Suivant', previous: 'Précédent', all: 'Tout',
    'match case': 'Respecter la casse', regexp: 'Expression régulière', 'by word': 'Mot entier', replace: 'Remplacer', 'replace all': 'Tout remplacer',
    close: 'Fermer', Done: 'Terminé', 'No results': 'Aucun résultat', '$1 of $2': '$1 sur $2', 'current match': 'Occurrence actuelle',
    'on line': 'à la ligne', 'replaced $ matches': '$ occurrences remplacées', 'replaced match on line $': 'Occurrence remplacée à la ligne $',
    'Image unavailable: ': 'Image indisponible : ',
    'Diagram could not be rendered: ': 'Impossible d’afficher le diagramme : ',
  },
  es: {
    Find: 'Buscar', Replace: 'Reemplazar', next: 'Siguiente', previous: 'Anterior', all: 'Todo',
    'match case': 'Coincidir mayúsculas', regexp: 'Expresión regular', 'by word': 'Palabra completa', replace: 'Reemplazar', 'replace all': 'Reemplazar todo',
    close: 'Cerrar', Done: 'OK', 'No results': 'Sin resultados', '$1 of $2': '$1 de $2', 'current match': 'Coincidencia actual',
    'on line': 'en la línea', 'replaced $ matches': '$ coincidencias reemplazadas', 'replaced match on line $': 'Coincidencia reemplazada en la línea $',
    'Image unavailable: ': 'Imagen no disponible: ',
    'Diagram could not be rendered: ': 'No se puede mostrar el diagrama: ',
  },
}

function pick(lang) {
  if (TABLES[lang]) return TABLES[lang]
  // zh-HK, zh-TW and the like map to Traditional by script, other Chinese maps to Simplified; other languages use the primary language code
  if (/^zh-(Hant|HK|TW|MO)/i.test(lang)) return TABLES['zh-Hant']
  if (/^zh/i.test(lang)) return TABLES['zh-Hans']
  return TABLES[lang.split('-')[0]] || {}
}

/** The string table for the current UI language, ready to pass to EditorState.phrases. */
export const phrases = pick(window.__nibSettings?.lang || 'en')

/** Fetches one string; falls back to the English original when untranslated. */
export const t = (key) => phrases[key] ?? key
