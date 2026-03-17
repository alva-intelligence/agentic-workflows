"use client";

import { useEffect, useState } from "react";
import { BaseLayout } from "@/components/frndos/layout/BaseLayout";
import { CardMetric } from "@/components/frndos/CardMetric";
import Link from "next/link";

interface WireframeMetadata {
  feature: string;
  wireframe: string;
  title: string;
  prd: string;
  owner: string;
  status: string;
  created: string;
  approved_by: string | null;
  approved_at: string | null;
}

interface FeatureGroup {
  slug: string;
  wireframes: WireframeMetadata[];
}

export default function WorkflowsIndexPage() {
  // This page reads from the filesystem at build time in a real implementation
  // For now, show a placeholder that lists feature directories

  return (
    <BaseLayout>
      <div className="p-6">
        <h1 className="text-2xl font-bold mb-2">Wireframe Library</h1>
        <p className="text-gray-500 mb-6">
          Browse feature wireframes. Each feature may have multiple wireframe
          pages.
        </p>

        <div className="bg-yellow-50 border border-yellow-200 rounded-lg p-4 mb-6">
          <p className="text-sm text-yellow-800">
            <strong>Development only.</strong> This page is not available in
            production. Create wireframes using <code>/wireframe create</code>.
          </p>
        </div>

        {/* Feature cards will be dynamically populated based on existing wireframe directories */}
        <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4">
          <div className="border border-dashed border-gray-300 rounded-lg p-6 text-center text-gray-400">
            <p className="text-lg mb-2">No wireframes yet</p>
            <p className="text-sm">
              Start with <code>/workflow start &lt;slug&gt;</code> to create a
              feature, then <code>/wireframe create &lt;slug&gt;</code> to build
              wireframes.
            </p>
          </div>
        </div>
      </div>
    </BaseLayout>
  );
}
