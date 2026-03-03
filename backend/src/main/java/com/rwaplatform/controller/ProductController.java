package com.rwaplatform.controller;

import com.rwaplatform.dto.ProductDto;
import com.rwaplatform.service.ProductService;
import lombok.RequiredArgsConstructor;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;

import java.util.List;
import java.util.Map;

@RestController
@RequestMapping("/api/v1/products")
@RequiredArgsConstructor
public class ProductController {

    private final ProductService productService;

    /** 查询所有活跃产品列表 */
    @GetMapping
    public ResponseEntity<Map<String, Object>> listProducts() {
        List<ProductDto> products = productService.listProducts();
        return ResponseEntity.ok(Map.of("products", products));
    }

    /** 查询单个产品详情 */
    @GetMapping("/{id}")
    public ResponseEntity<?> getProduct(@PathVariable String id) {
        ProductDto dto = productService.buildProductDto(id);
        if (dto == null) {
            return ResponseEntity.notFound().build();
        }
        return ResponseEntity.ok(dto);
    }
}
