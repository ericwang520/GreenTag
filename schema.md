# 事件 Schema — vision → agent（唯一接口，改动必须两人同意）

## ViolationEvent

vision 服务检测到违规时，POST 到 agent 的 `/events` 端点（或写入共享队列）：

```json
{
  "violation_type": "stud_spacing",
  "measured_value": 19.0,
  "unit": "in",
  "expected": "16in OC",
  "code_ref": "IRC R602.3(5)",
  "confidence": 0.87
}
```

## 字段约定

| 字段 | 类型 | 说明 |
|---|---|---|
| `violation_type` | string | 目前只有 `stud_spacing`，扩展时加新值（如 `outlet_height`） |
| `measured_value` | number | **必须是数字**，不带单位后缀 |
| `unit` | string | **永远是 `"in"`（英寸）**——单位写死，禁止厘米 |
| `expected` | string | 人话描述的标准值 |
| `code_ref` | string | 条款编号，agent 拿它去 Moss 检索原文 |
| `confidence` | number | 0-1；低于 0.6 时 agent 用"可能/请再扫一次"措辞 |

## 约定

- Plan A/B/C（真实检测/混合/mock）都输出**同一格式**——下游不感知数据来源
- 字段只增不改不删
