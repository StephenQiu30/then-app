# 单件图内容检测隔离素材

## 2026-09-14身体部位边界素材

`synthetic-hands-on-shirt.png` 由内置 imagegen 原创生成，未输入参考图，未在生成后编辑。人工查看确认：一件完整蓝色短袖、两只明显成人手及前臂、没有脸或躯干；此图包含身体部位，不符合无人物单件素材条件。manifest v3 登记生成 ID `exec-93fb6a01-a258-4f7e-94c5-66f106366721`、实际 1254×1254、2,013,573 字节、SHA-256 `3954a826eea83db3e3c7f452c9ff4fb1404cf3897f09b761c8663df590122c7a`。没有把“人数”与身体部位数量混用，也没有预先把 Vision 输出填为 ground truth。

生成约束为：虚构成人手部在白色桌面上抚平完整蓝色 T 恤，俯拍、自然清晰的手指和短前臂，没有脸/头/颈/躯干/腿/完整人物、其他衣物、品牌、首饰、文字或拼贴。此文件只进入测试资源，不能加入生产 App、默认衣橱或原三图系统图库种子脚本；目的为拒绝边界，不是训练素材或完整准确率校准。

实际提示词（内置工具，未使用 CLI）：

> Use case: photorealistic-natural. Asset type: original synthetic iOS wardrobe safety test fixture, square image around 1024 by 1024. Generate a single overhead photograph-like image of a plain blue adult T-shirt lying fully visible on a white table. Two clearly visible adult human hands and short forearms enter from the bottom edge, resting naturally on the lower part of the shirt as if smoothing fabric. The hands must have realistic anatomy and be large, clear, unobscured. Absolutely no face, head, neck, torso, legs, full person, text, logos, jewelry, tattoos, watermark, collage or extra garments. The shirt is the only clothing item. Soft even studio lighting. This is entirely fictional adult anatomy, no real person or reference photo. Purpose is testing that an image containing body parts is not mistaken for a person-free garment catalog image.

实测：既有 512px 人物/面部请求 people=0/faces=0；独立手部请求 revision 1 在 512px/原图 × CPU/system 四组均返回 0。人体内容标签保持不变；自动拒绝与手部探针均作为失败证据保留，不能用其替换生产检测器或声称完成安全矩阵。

2026-09-13 在用户已批准项目实现和测试范围内，使用内置 imagegen 原创生成两张图片；没有参考照片、真实人物或用户衣橱数据。图片已逐张查看，SHA-256、实际尺寸、生成结果 ID 与预期标签记录在 manifest.json。只进入 ThenAppTests Resources，不进入 App 产品资源或默认衣橱。

- synthetic-one-adult：完全虚构成人，蓝色不透明 T 恤、米色长裤、白色鞋，单人完整站立，头和双脚可见，浅灰背景，无其他人物/镜面；画面角落标注 SYNTHETIC TEST。预期人物 1、面部 1、可分离前景实例 1。
- synthetic-flat-shirt：单件蓝色平铺短袖 T 恤，衣领、袖口和下摆完整，浅灰背景，没有人物、身体部位、人体模型、衣架、其他衣物或品牌；同样标注 SYNTHETIC TEST。预期人物 0、面部 0、前景实例 1。

两张图分别使用上述完整主体、场景与约束生成，未在生成后裁切或编辑。请求尺寸分别为 1024×1536 和 1024×1024；生成器实际第二张为 1254×1254，manifest 与测试使用实际字节/尺寸而非提示词尺寸。

这些标签在 Vision 运行前根据图像检查登记，不按检测输出倒填；意外输出必须保留为失败。前景实例数仅为探针预期，不能当成通用衣物计数。合成样本只验证两个样本上的系统能力，不证明真实用户误识别率、多人/遮挡/模糊、不同设备/人群、内容安全或生产门禁。11-01 的完整 SEC-01 素材门禁不因此完成。

## 2026-09-14不同图片替换素材

新增 `synthetic-red-sweater.png`，通过内置 imagegen 原创生成，无参考图或真实用户数据。已人工查看：单件红色圆领长袖针织衫完整平铺，袖口/下摆完整、没有人物或身体部位；浅灰背景右下角有 SYNTHETIC TEST。实际 1254×1254、2,413,433 字节，SHA-256 与生成 ID 记录在 manifest v2。文件未在生成后裁切、改色或重编码。

运行检测前预期为人物 0、面部 0、可分离前景 1；预期不是检测实测值。该样本补充不同像素换图/取消/重启的 UI 验收，不能抵扣完整安全矩阵。系统图库测试在全新、已启动的专用设备上执行 `python3 scripts/seed-wardrobe-photo-simulator.py <UDID>` 一次；脚本只在副本设置固定递增日期，原图字节不变。不能仅依赖 addmedia 的导入顺序。最新三项 index 0/1/2 应分别为蓝色短袖/成人/红色长袖，必须查看图库截图确认；2026-09-14 复验实际顺序与此一致。

完整生成提示词（内置工具，未使用 CLI）：

> Use case: product-mockup. Asset type: original synthetic garment photo for an iOS wardrobe application's isolated replacement tests. Generate one square 1024 by 1024 image: a single vivid red long-sleeved knitted crew-neck sweater laid completely flat on a clean light gray studio background. Top-down catalog photography, realistic knit texture, diffuse neutral light, minimal soft shadow. Entire garment fully visible with clear collar, cuffs, hem, both sleeves separated from torso and generous margin on all sides. Absolutely no people, faces, body parts, mannequins, hangers, accessories, other garments, logos or brands. Small clearly readable text 'SYNTHETIC TEST' in the bottom-right background corner. It must look visibly different in color and silhouette from a blue short-sleeve T-shirt. No reference images; wholly invented test garment, not a real product or user photo.
