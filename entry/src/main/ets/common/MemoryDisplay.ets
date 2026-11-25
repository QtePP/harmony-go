/** User-facing labels for the pinned ontology facts shown under a reply. */
export function memoryPredicateLabel(predicate: string): string {
  switch (predicate) {
    case 'name': return '姓名'
    case 'nickname': return '昵称'
    case 'pronoun': return '称谓'
    case 'language': return '语言'
    case 'timezone': return '时区'
    case 'birthday': return '生日'
    case 'city': return '城市'
    case 'occupation': return '职业'
    case 'employer': return '单位'
    case 'allergy': return '过敏'
    case 'diet': return '饮食'
    case 'avoids': return '避免'
    case 'likes': return '喜欢'
    case 'dislikes': return '不喜欢'
    case 'communication_style': return '沟通偏好'
    case 'relation': return '关系'
    case 'works_on': return '项目'
    case 'member_of': return '组织'
    case 'goal': return '目标'
    case 'deadline': return '截止'
    case 'met_on': return '见面'
    case 'promised': return '承诺'
    case 'note': return '备注'
    default: return predicate
  }
}

/** Where the fact came from, in the same words the ontology panel uses. */
export function memorySourceLabel(source: string): string {
  if (source === 'user') {
    return '你告诉它的'
  }
  if (source === 'model') {
    return '它从对话里记的'
  }
  if (source === 'import') {
    return '导入'
  }
  return source.length > 0 ? source : '本机'
}
