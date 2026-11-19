# exp43 训练报告
**结论：**val_loss 降到 **0.187**，比 exp42 的 ~~0.198~~ 低 *5.6%*。
详见 [实验记录](https://example.com/exp43)，上一次的结果见 [exp42 完成](huijian://message/E42_ID)。

![训练进度](progress:45000/60000)
![评估](progress:1)

| 模型 | val_loss | top-1 | 用时 |
|:-----|---------:|------:|:----:|
| baseline | 0.231 | 91.7% | 3h |
| exp42 | 0.198 | 93.4% | 6h |
| **exp43** | **0.187** | **94.1%** | 7.5h |

> [!SUCCESS] 评估通过
> 全部指标超过 baseline，可以开始消融实验。

> [!WARNING] 磁盘已用 **92%**
> `/data` 只剩 36 GB，下次训练前清理旧的 checkpoint。

> [!INFO]- 完整日志（点按展开）
> ```
> step 45000  loss 0.187  lr 1.2e-4  grad_norm 0.82
> step 44000  loss 0.189  lr 1.3e-4  grad_norm 0.85
> ```

> [!TIP] 加 `--resume` 可以从断点继续训练

> [!IMPORTANT] 周五前提交评估结果

> [!CAUTION] 不要直接删除 /models 目录

> [!FAILURE] exp43-b 显存不足，已中断

![损失曲线（验证集）](attachment:loss.png)

## 待办
- [x] 数据清洗
- [x] 训练 exp43
- [ ] 消融实验
  1. 去掉数据增强
  2. 换成 AdamW

> 下周例会讨论
> > 记得带上混淆矩阵

---
加载最佳权重[^1]：

```python
model.load_state_dict(torch.load("exp43/best.pt", map_location="cpu"))
model.eval()
```

![评估报告](attachment:report.pdf)
也可以直接打开 [report.pdf](attachment:report.pdf)。外部图片默认不加载：

![吞吐量曲线](https://example.com/throughput.png)

[^1]: checkpoint 在 NAS 的 `/models/exp43/` 目录。
